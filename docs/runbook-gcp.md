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
| Google 帳號 | BigQuery Sandbox **免信用卡、免計費帳戶**（見下表）|
| gcloud CLI | 見下方「gcloud 只為了一件事」 |
| 應用程式預設憑證 | `gcloud auth application-default login`——**不要下載服務帳號金鑰檔**，那是最常見的外洩來源 |
| dbt | `python -m venv .venv-dbt && ./.venv-dbt/bin/pip install "dbt-bigquery>=1.9" pandas pyarrow` |

### gcloud 只為了一件事：取得 ADC

`dbt-bigquery` 與本專案的載入腳本都走 REST API（`google-cloud-bigquery`），
**不需要 `bq` CLI**。CLI 唯一不可取代的用途是 `gcloud auth application-default login`
——它會開瀏覽器讓你用 Google 帳號登入，把憑證寫到本機。

所以 `bq load` 被 [`etl/load_bigquery.py`](../etl/load_bigquery.py) 取代，
附帶好處是**綱要在程式裡寫死而不是靠 `--autodetect` 猜**：
autodetect 猜錯型別不會報錯，只會讓下游 `cast` 悄悄產生 NULL。
金額欄一律 `NUMERIC` 不用 `FLOAT64`——這是錢，浮點誤差在單筆看不出來，
在 18 萬列的 `SUM` 上就會跟 SQL Server 版的 `DECIMAL(14,2)` 對不起來，
而對帳對不起來時你會先懷疑邏輯、最後才想到型別。

> **macOS 安裝踩點（2026-08-10 實測）**：`brew install --cask google-cloud-sdk` 會在
> 內部的 pip 步驟失敗（`Failed to resolve 'github.com'`）然後把安裝**整個 purge 掉**，
> 而同一台機器上 `curl`／`pip` 直連完全正常——是 cask 安裝程序的巢狀環境問題。
> 改用官方安裝方式（`https://cloud.google.com/sdk/docs/install-sdk` 的 macOS 版），
> 或只裝 `gcloud` 本體後略過 CLI 的其他元件。

### Sandbox 的限制（查證於官方文件，2026-08-10）

| 限制 | 值 | 對本專案的影響 |
|---|---|---|
| 信用卡／計費帳戶 | **不需要** | 這是唯一真正的**硬性**成本上限——沒有計費帳戶就不可能產生帳單 |
| 作用中儲存 | 10 GB／月 | 18 萬列事實表 + 維度遠低於此 |
| 查詢處理量 | 1 TB／月 | 全量重建掃描 < 100 MB |
| 資料表過期 | **60 天後自動過期，且不能設更長** | 對短命環境正好；但別把它當備份 |
| **不支援 DML** | `INSERT`／`UPDATE`／`DELETE`／`MERGE` | **見下方警告** |
| 不支援串流插入、Data Transfer Service | — | 本專案都沒用到 |

> ⚠️ **不支援 DML 這條會直接決定 dbt 能不能跑（2026-08-10 實測確認，非引用文件）**：
>
> ```
> DDL (CREATE OR REPLACE TABLE AS SELECT) : 可用
> DML (UPDATE)  : 403 Billing has not been enabled ... DML queries are not allowed in the free tier.
> DML (MERGE)   : 同上
> ```
>
> 本專案的模型全部是 `view` 與 `table` 兩種 materialization，產生的是
> `CREATE OR REPLACE VIEW／TABLE ... AS SELECT`——那是 **DDL，Sandbox 支援**。
> seed 走載入作業，也不是 DML——**`dbt seed` 的日誌會印 `INSERT n`，那是 dbt 的措辭，
> 實際送的是載入作業**，別被它誤導成「Sandbox 其實支援 DML」。所以現況可以跑完。
>
> **但只要有人把任何模型改成 `incremental`，dbt 就會產生 `MERGE`，在 Sandbox 上直接失敗。**
> 真要做增量，就得啟用計費帳戶——而那一刻起「不可能產生帳單」的保證就沒了。
> 這個取捨要自覺地做，不要在某次 refactor 裡順手改掉。

`profiles.yml.example` 另設 `maximum_bytes_billed: 1 GB`：即使日後啟用計費，
跑錯查詢也會**直接失敗**而不是產生帳單。這是第二層護欄，不是第一層——
第一層永遠是「不啟用計費帳戶」。

---

## 2. 載入來源

兩邊必須吃**同一份 export**，否則對帳比的是兩份資料而不是兩套實作。

```bash
# 產出與 SQL Server 版同源的 CSV 快照（若 data/source_credit_clients.csv 已存在可略過）
./.venv/bin/python etl/export_source_csv.py

# 建 dataset + 載入（明確綱要，不用 autodetect）
./.venv-dbt/bin/python etl/load_bigquery.py --project <PROJECT_ID> --location asia-east1
```

腳本會驗證載入列數與來源一致（30,000），不一致就直接失敗。
來源的目標欄 `default` 會改名為 `default_next_month`——與 SQL Server 版的暫存層一致，
且 `default` 是 SQL 保留字，留著會逼得每個查詢都要跳脫。

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

實跑結果（2026-08-10）：`fact_monthly_statement` **180,000** 列、
`fact_default_outcome` **30,000** 列、`dim_customer` **51,110** 個版本——
與 SQL Server 版逐項相同。seed 10.6 秒、run 12.7 秒、test 5.4 秒。

> **踩過的兩個坑**：
> 1. `accepted_values` 的值不加 `quote: false`，dbt 會渲染成字串，與 `INT64` 欄位比較
>    直接報 `No matching signature for operator IN`。BigQuery 是強型別，這在
>    SQL Server 那邊不會發生。
> 2. 載入時 pandas 的 `float64` 送不進 `NUMERIC`，會炸
>    `Got bytestring of length 8 (expected 16)`（float64 8 bytes、decimal128 16 bytes）。
>    正解是轉 `Decimal`，**不是**把綱要改成 `FLOAT64`——後者能「跑過」，
>    但那等於為了讓程式不報錯而把錢改成近似值。

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
./.venv-dbt/bin/python etl/load_bigquery.py --project <PROJECT_ID> --teardown
```

腳本刪完會**列出帳戶內剩餘的 dataset**——空的才回傳 0。

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
| 免費方案的陷阱 | 規格上限（開不起來，明顯） | 額度用完**靜默計費**（危險） | Sandbox 不支援 DML——改用 incremental 就得啟用計費 |
| 成本上限的**硬度** | 軟（預算警示只通知，不阻擋） | 軟（同左） | **硬**（沒有計費帳戶就不可能產生帳單） |

一句話：**能跨三家的不是 SQL，是綱要與驗收條件。**
把「不一樣的地方」收斂到一個明確介面（`DW_PLATFORM` ＋環境變數 ＋ dbt 模型層），
每個差異都寫清楚為什麼——這比「到處都能跑」更接近真實的多雲工作。
