# 資料治理標準

這份文件把本專案**已經在執行**的規則寫成標準——每一條都指向程式碼或 CI 裡實際擋人的那個位置。
沒有對應執行點的規則不收：寫在文件裡但沒有東西擋的「標準」，第二個月就沒人遵守。

適用範圍：單一專案（信用卡風險倉儲，30,000 卡戶）。這不是組織級治理框架，
是「一個倉儲要能讓第二個人接手」所需的最小規則集。

---

## 1. 分層契約

| 層 | 綱要 | 准做什麼 | 不准做什麼 | 執行點 |
|---|---|---|---|---|
| 來源落地 | `stg` | 與來源同構落地、記 `load_batch_id` | 任何業務轉換 | `sql/01_schema.sql`；dbt `_sources.yml` 宣告為 source |
| 暫存 | `dbt_stg`（dbt）| 欄名正規化、型別收斂 | 業務邏輯、聚合 | `stg_credit_clients.sql` 檔頭註解＝契約 |
| 維度／事實 | `dw`／`dbt_dw` | 星狀綱要、SCD2、粒度守衛 | 存比率（存分子分母） | `_marts.yml` 粒度測試；`bi/README.md` 比率規則 |
| 品質 | `dq` | 規則登錄、逐批結果 | 只印終端不落地 | `sql/04_quality_checks.sql` 立場段 |
| 語意 | `_semantic.yml` | 指標唯一定義 | 在報表端另算一份 | dbt parse（結構）；exposures 標記下游 |

「暫存層不轉換」的理由：轉換混進落地層，出問題時分不清是來源髒還是自己弄髒的。

## 2. 命名

- 綱要以層命名（`stg`／`dw`／`dq`），不以團隊或專案命名——層是穩定的，組織不是。
- 維度 `dim_*`、事實 `fact_*`、代理鍵 `*_sk`、自然鍵保留來源名（`client_id`）、日期鍵 `date_key`（yyyymm 整數）。
- 品質規則有穩定的 `rule_code`（`FACT_GRAIN`、`SCD2_NO_OVERLAP`…），程式與報表都用代碼不用序號——序號會因插入而位移。
- dbt 測試名以「規則對應」註解：每條 dbt 測試在 `_marts.yml` 都標明對應 SQL Server 版哪條 `dq` 規則，兩套實作的規則集可逐條對照。

## 3. 粒度與比率

- **每張事實表宣告粒度，並以測試守衛**：`fact_monthly_statement`＝客戶 × 月（`unique_combination_of_columns` 測試）；`fact_default_outcome`＝客戶（與帳單事實分表，否則違約旗標被數六次）。
- **比率一律存分子分母**：倉儲層、BI 匯出（`bi/extract/`）、語意層三處同一條規則。理由：對每列比率取平均是「平均的平均」，小額與大額帳戶被當成等權。
- **時點正確性**：事實列接的是「當月有效」的維度版本——時序條件寫在 JOIN，**絕不寫 `WHERE is_current = 1`**（那會讓歷史事實全部指向最新版本，且不會報錯）。執行點：`fact_monthly_statement.sql` 的 JOIN 述詞；同庫對帳（`analyses/reconcile_edge_dbt_vs_procs.sql`）逐客戶逐月驗證。

## 4. 品質規則的登錄與分級

- 規則登錄在 `dq.quality_rule`（代碼、嚴重度、說明），結果逐批落在 `dq.quality_result`（檢了幾列、幾列失敗、失敗樣本摘要）。「這批資料當時的品質」可回溯。
- **ERROR vs WARN 的分野是治理決策，不是技術決策**：ERROR＝倉儲自身邏輯壞（粒度重複、孤兒鍵、版本重疊），必須修、擋住下游；WARN＝來源本來就這樣（未定義碼值、超額帳單），標記但不阻擋。把來源髒資料判成 ERROR 會讓整條線天天紅燈，紅燈久了沒人看——比不檢核更糟。
- 執行點：Airflow DAG 的 `quality_gate` 任務擋在資料字典產出之前（CI 驗證這個順序沒被改掉）；dbt 端 34 條測試在 `dbt build` 中任一 ERROR 即停。
- 樣本摘要欄放「摘要」不放「明細」（第一版 STRING_AGG 三萬列直接爆 NVARCHAR(400)）。

## 5. 指標的單一事實來源

- 三個業務指標（違約率、逾期率、額度使用率）在 `dbt/models/marts/_semantic.yml` 各定義一次：分子分母各是一個 measure、粒度綁在對應的 semantic model 上。
- 下游（Tableau 儀表板、BI 匯出）的計算欄位照這個定義寫，**不得自行重定義**；`bi/README.md` 的計算欄位規格與語意層逐一對應。
- 改指標定義的流程：改 `_semantic.yml` → `dbt parse` → `python tools/lineage_md.py` 重產血緣 → PR 裡看 exposures 標記的受影響下游 → 更新儀表板。

## 6. 血緣與文件：產出，不手寫

| 文件 | 產出方式 | 為什麼不手寫 |
|---|---|---|
| `docs/data_dictionary.md` | `etl/gen_data_dictionary.py` 讀 `sys.tables`／`sys.columns`／擴充屬性 | 手寫字典第二次改綱要就過期，而且沒人發現 |
| `docs/lineage.md` | `tools/lineage_md.py` 讀 dbt `manifest.json` | 血緣來自 `ref()`／`source()`／exposures 宣告，改模型自動反映 |
| dbt docs（`dbt docs generate`） | 模型／欄位 description＋catalog | 逐欄文件與血緣圖同一份來源 |

- **CI 守衛**：`lineage_md.py --check` 在 CI 跑——模型或 exposure 改了、血緣文件沒重產，PR 紅燈。文件漂移從「靠自覺」變成「機器擋」。
- 資料字典只在品質閘通過後產出（DAG 順序），所以它描述的永遠是「通過稽核的那一版綱要」。

## 7. 模型即程式碼：變更流程

- 所有綱要、ETL、dbt 模型、品質規則、語意層定義都在 git；沒有「在資料庫裡直接改」這條路。
- 每個 PR 過五道 CI：DAG 可解析且 SCD2 時序鏈未斷、SQL 檔靜態檢查、可攜層回歸測試、dbt 雙 adapter parse（核心模型與粒度／SCD2 測試必須存在）、血緣文件一致。
- 每道守衛都以突變體驗證過會擋下違規（例：把 `quality_gate` 移到字典之後、把粒度測試拿掉），守衛自己也要被測。

## 8. 誠實邊界

- 規模是**單一專案、單一資料集**；沒有資料擁有者制度、存取控制矩陣、跨部門指標委員會——那些是組織層治理，這裡沒有對應的組織。
- 語意層只驗到 `dbt parse` 的結構正確；MetricFlow 查詢端需 dbt Cloud 或支援的 adapter，本地 T-SQL target 未跑。
- 血緣是表級與指標級；欄位級血緣 dbt 未內建，本專案未做。
