# Airflow 編排層

把 [`etl/run_etl.py`](../etl/run_etl.py) 的單機流程升級成 Airflow DAG。**單機腳本仍然可用**——這一層加的不是「換個方式跑同一件事」，而是三個腳本裡看不見的編排語意：

| 語意 | 在腳本裡 | 在 DAG 裡 |
|---|---|---|
| SCD2 逐月由舊到新（正確性約束） | for-loop 的迭代順序，隱含 | 六個月份任務串成顯式依賴鏈，調度層面不可能亂序；任一月失敗即中斷，不會帶著錯的維度版本繼續 |
| 品質稽核 | 跑完印報表、回傳 exit code | **品質閘任務**：ERROR 級規則失敗 → DAG 失敗，資料字典不會在髒資料上產出 |
| 批次收尾 | 成功才標 `SUCCEEDED` | `finalize` 以 `trigger_rule=ALL_DONE` 對稱收尾：成功標 SUCCEEDED、失敗標 FAILED，`dq.load_batch` 不留 RUNNING 殭屍批次 |

冪等性沿用倉儲層既有設計（事實表先刪後插、SCD2 雜湊比對）。這在 Airflow 是硬前提：任務會重試，**不冪等的任務配上重試等於自動化地製造重複資料**。

```
apply_schema ──> load_staging ──> ix6 ──> ix5 ──> ix4 ──> ix3 ──> ix2 ──> ix1 ──> load_outcome ──> quality_gate ──┬──> gen_data_dictionary
                                 （200504 → 200509，SCD2 時序鏈）                                                  └──> finalize（ALL_DONE）
```

## 執行

```bash
# 一次性：在宿主機產出來源 CSV 快照（容器看不到隔壁 repo 的 OpenML 快取）
./.venv/bin/python etl/export_source_csv.py   # 已隨 repo 附上 data/source_credit_clients.csv

cd airflow
docker compose up -d          # sqledge + airflow standalone，首次拉映像約數分鐘
# UI: http://localhost:8080（admin / admin）
docker compose exec airflow airflow dags trigger credit_dw_etl
```

驗證與單機路徑相同的落地結果：事實 180,000 列、維度 51,110 版本、ERROR 級規則 0 失敗（實測兩輪 DAG run 皆 success，落地筆數逐輪相同）。

**重跑語意要說清楚**：整條 pipeline 沿用單機路徑的 **full refresh** 設計——`apply_schema` 每輪重建綱要後全量重載，「重跑筆數不變」是決定性重建的結果，批次歷史不跨輪保留；**單一輪之內**的冪等（事實表先刪後插、SCD2 雜湊比對）才是任務重試不產生重複列的保證。接真實增量源時，`apply_schema` 應改為 migration 式（不 DROP），屆時 `dq.load_batch` 才會累積跨輪歷史。

## 誠實邊界（面試據實陳述）

- `airflow standalone`＝SQLite 中繼庫＋SequentialExecutor 的**單機示範配置**；生產環境應換 Postgres 中繼庫＋LocalExecutor/CeleryExecutor 並 build 自訂映像（而非 `_PIP_ADDITIONAL_REQUIREMENTS` 開機安裝）。本層的重點是 DAG 編排語意，不是叢集部署。
- `schedule=None` 手動觸發：這份資料是歷史批次快照，掛 cron 是假語意。真實資料源接上時，改 `schedule` 並把 `load_staging` 換成增量抽取即可，圖形不變。
- sa 密碼為本機一次性開發憑證（只綁 127.0.0.1、隨 `down -v` 消失），非生產做法。
