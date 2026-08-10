# Runbook：在 BigQuery 上重現本專案（dbt）

第三朵雲，而且是**唯一一個不能照搬 T-SQL 的**。這份文件的重點不是「怎麼跑」，
是「為什麼這朵雲需要重寫，以及重寫時什麼可以變、什麼不准變」。

---

## 0. 為什麼 BigQuery 不能照搬

AWS RDS 與 Azure SQL Database 都是 SQL Server 引擎，同一套預存程序原封不動就能跑。
BigQuery 不是——它沒有 `IDENTITY`、沒有叢集索引、預存程序語法不同、也不鼓勵逐列迴圈。

所以這一朵雲走 **dbt**：把同一份倉儲**重新表達**成模型，而不是把 T-SQL 硬翻。
關鍵紀律是——**可攜的是語意，不是實作**：

| 東西 | SQL Server 版 | BigQuery 版 | 准不准變 |
|---|---|---|---|
| 星狀綱要與粒度 | 12 表、事實粒度＝客戶×月 | 相同 | **不准變** |
| SCD2 的追蹤欄位 | `risk_tier` | 相同 | **不准變** |
| 12 條品質規則的語意 | `dq` 綱要 + 預存程序 | dbt tests（`macros/tests.sql`） | **不准變** |
| 風險分層的違約率 | HIGH 69.6% / LOW 13.2% | 必須相同 | **不准變** |
| SCD2 的算法 | 逐月預存程序 MERGE | 視窗函數一次算完 | 可以變 |
| 代理鍵 | `IDENTITY`（單調遞增） | `FARM_FINGERPRINT`（確定性雜湊） | 可以變 |
| 效能結構 | 索引 + INCLUDE 欄 | 分區裁剪 + 叢集 | 可以變 |
| 區間端點慣例 | 封版寫「前一個月」 | 寫「下一版起始月」 | 可以變 |

最後四項是**引擎的本質差異**，硬要一致只會寫出彆扭且慢的 SQL。
前四項一致與否，用 `dbt/analyses/reconcile_with_sqlserver.sql` 對帳。

---

## 1. 前置

| 項目 | 說明 |
|---|---|
| Google 帳號 | BigQuery Sandbox **免信用卡**；每月 1 TB 查詢免費額度 |
| gcloud CLI | `brew install --cask google-cloud-sdk`，`gcloud init` |
| 應用程式預設憑證 | `gcloud auth application-default login`——**不要下載服務帳號金鑰檔**，那是最常見的外洩來源 |
| dbt | `python -m venv .venv-dbt && ./.venv-dbt/bin/pip install "dbt-bigquery>=1.9"` |

Sandbox 的三個限制要先知道，免得誤判成 bug：

- 所有資料表 **60 天後自動過期**，且不能設更長 —— 對短命環境正好
- 每月 1 TB 查詢額度；本專案全量重建掃描 **< 100 MB**
- profiles 有 `maximum_bytes_billed: 1 GB`：跑錯查詢時**直接失敗**而不是產生帳單

---

## 2. 載入來源

兩邊必須吃**同一份 export**，否則對帳比的是兩份資料而不是兩套實作。

```bash
# 產出與 SQL Server 版同源的 CSV 快照
./.venv/bin/python etl/export_source_csv.py     # 產生 data/credit_clients.csv

PROJECT=$(gcloud config get-value project)
bq --location=asia-east1 mk --dataset "${PROJECT}:credit_dw_raw"
bq load --source_format=CSV --autodetect --replace \
  "${PROJECT}:credit_dw_raw.credit_clients" data/credit_clients.csv
```

---

## 3. 跑 dbt

```bash
cd dbt
cp profiles.yml.example profiles.yml   # 填 project / dataset / location
export DBT_PROFILES_DIR=.

../.venv-dbt/bin/dbt seed      # 五張參考維度（與 SQL Server 版同源匯出）
../.venv-dbt/bin/dbt run       # 5 個模型
../.venv-dbt/bin/dbt test      # 34 項測試，對應 SQL Server 版的 dq 規則
```

預期：`fact_monthly_statement` 180,000 列、`fact_default_outcome` 30,000 列、
`dim_customer` 的版本數與 SQL Server 版一致。

> 沒有憑證也能驗到這一步：`dbt parse` 與 `dbt list` **不連線**，
> 專案結構、Jinja 與測試定義有錯會當場報出來。CI 跑的就是這一關。

---

## 4. 對帳（這一步才是重點）

```bash
../.venv-dbt/bin/dbt compile --select reconcile_with_sqlserver
bq query --use_legacy_sql=false < target/compiled/dw_credit_star/analyses/reconcile_with_sqlserver.sql
```

把結果與 SQL Server 版的對應查詢逐列比對。**三組數字必須一致**：

1. 列數：事實 180,000、結果 30,000、維度版本數、自然鍵數
2. 每個月每個 risk_tier 的客戶數（SCD2 的語意本體）
3. 風險分層的違約率（HIGH / MEDIUM / LOW）

不比代理鍵的值，也不比 `valid_to_date` 的端點數字——那兩項本來就不同，
比它們只會比出「實作不同」，那是已知的，不是要驗的東西。

---

## 5. 拆除

Sandbox 的表 60 天自動過期，但別依賴那個：

```bash
bq rm -r -f --dataset "${PROJECT}:credit_dw"
bq rm -r -f --dataset "${PROJECT}:credit_dw_raw"
bq ls --datasets "${PROJECT}"     # 實查：兩個 dataset 都不在
```

同 AWS／Azure 的紀律：**「指令沒報錯」與「雲端帳戶裡沒有東西」是兩件事**。

---

## 6. 三朵雲擺在一起，學到什麼

| | AWS RDS | Azure SQL Database | BigQuery |
|---|---|---|---|
| 引擎 | SQL Server | SQL Server | 專有欄式 |
| T-SQL 可攜性 | 原封不動 | **略過 2 種批次**（DB 由 IaC 建） | **不可攜，重新表達** |
| 資料庫的資源粒度 | 執行個體內的物件 | 資源本身 | dataset |
| 代理鍵 | IDENTITY | IDENTITY | 確定性雜湊 |
| 效能結構 | 索引 | 索引 | 分區＋叢集 |
| 成本護欄 | 關閉 autoscaling ＋預算警示 | serverless auto-pause | 查詢位元組上限 |
| 免費方案的陷阱 | 規格上限（開不起來，明顯） | 額度用完靜默計費（危險） | 表 60 天過期（對短命環境無害） |

一句話：**能跨三家的不是 SQL，是綱要與驗收條件。**
把「不一樣的地方」收斂到一個明確介面（`DW_PLATFORM` ＋環境變數 ＋ dbt 模型層），
每個差異都寫清楚為什麼——這比「到處都能跑」更接近真實的多雲工作。
