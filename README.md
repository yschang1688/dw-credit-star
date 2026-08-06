# 信用卡風險資料倉儲（星狀綱要 · SQL Server T-SQL）

[![checks](https://github.com/yschang1688/dw-credit-star/actions/workflows/checks.yml/badge.svg)](https://github.com/yschang1688/dw-credit-star/actions/workflows/checks.yml)

把橫斷面寬表轉成可分析的維度模型：**星狀綱要、SCD Type 2、預存程序 ETL、資料品質稽核、自動產出的資料字典**。
**全程容器化**——資料庫引擎跑在容器裡，從空機到載完 18 萬列事實並通過稽核約 3 分鐘，任何機器上結果相同。

> **In brief** — A credit-risk data warehouse in T-SQL: Kimball star schema, Slowly Changing
> Dimension Type 2 with verified point-in-time joins, stored-procedure ETL, and a data-quality
> layer whose rules persist per batch. Built on the UCI Taiwan credit-card default dataset.
> The whole stack runs in a container (arm64-native Azure SQL Edge), reproducible end-to-end
> in about three minutes.

## 完整重現

```bash
docker run -d --name creditdw -e "ACCEPT_EULA=1" -e "MSSQL_SA_PASSWORD=DwStar!2026dev" \
  -e "MSSQL_PID=Developer" -p 11433:1433 mcr.microsoft.com/azure-sql-edge:latest

python -m venv .venv && ./.venv/bin/pip install -r requirements.txt
./.venv/bin/python etl/run_etl.py               # 綱要 → 載入 → 稽核，約 3 分鐘
./.venv/bin/python etl/gen_data_dictionary.py   # 產出 docs/data_dictionary.md
```

容器映像選用 **Azure SQL Edge（原生 arm64）** 而非 SQL Server 2022，是實測後的被迫取捨：後者在 Apple Silicon 上以模擬層執行會直接崩潰。原因與排查過程見[環境備註](#環境備註為什麼是-azure-sql-edge-而不是-sql-server-2022)。

| 你想看 | 去這裡 |
|---|---|
| SCD Type 2 怎麼實作（含 row_hash 變更偵測、時點正確的事實關聯） | [`sql/03_procedures.sql`](sql/03_procedures.sql) |
| 品質規則怎麼設計（ERROR／WARN 分級、規則登錄化） | [`sql/04_quality_checks.sql`](sql/04_quality_checks.sql) |
| 星狀綱要與粒度守衛 | [`sql/01_schema.sql`](sql/01_schema.sql) |
| 星狀綱要讓哪些問題變好問 | [`sql/05_analysis_queries.sql`](sql/05_analysis_queries.sql) |
| 容器化執行環境與跨平台取捨 | [環境備註](#環境備註為什麼是-azure-sql-edge-而不是-sql-server-2022) |
| Airflow 編排（SCD2 時序依賴鏈、品質閘、批次對稱收尾；兩輪實跑驗證） | [`airflow/`](airflow/) |
| Kubernetes 部署（StatefulSet／Job／就緒探針；叢集實跑＋冪等驗證） | [`k8s/`](k8s/) |
| 互動儀表板（遷移矩陣、分層鑑別力、逾期率趨勢、品質看板） | [Tableau Public](https://public.tableau.com/app/profile/yu.sheng.chang/viz/credit-risk-dw-dashboard/1)・規格見 [`bi/`](bi/) |
| Kubernetes 部署（StatefulSet／Job／就緒閘；Compose 直譯會壞掉的三個地方） | [`k8s/`](k8s/) |
| 資料字典（由系統目錄自動產出） | [`docs/data_dictionary.md`](docs/data_dictionary.md) |


來源：UCI「default of credit card clients」（台灣某銀行 2005，30,000 卡戶，六個月帳單／繳款）。
原始結構是一列一個客戶、把六個月攤成 18 個欄位的寬表——問「哪些客戶風險升高了」得寫六段 UNION。

```
來源寬表 30,000 列
      │  抽取
      ▼
stg.credit_clients          與來源同構，不做轉換
      │  逐月由舊到新
      ▼
dw.dim_customer  (SCD2)  ──┐   51,110 個版本
dw.dim_date / education /  ├──> dw.fact_monthly_statement   180,000 列
   marriage / sex /        │    dw.fact_default_outcome      30,000 列
   payment_status          ┘
      │
      ▼
dq.quality_rule / quality_result     12 條規則，隨每批次落地
      │
      ▼
docs/data_dictionary.md              從 sys.tables 自動產出
```

## 實跑結果

```
[4/5] 逐月載入維度與事實（由舊到新）
  200504（第 6 近月）→ 事實 30,000 列｜維度累計 30,000 版本
  200505（第 5 近月）→ 事實 30,000 列｜維度累計 32,550 版本
  200506（第 4 近月）→ 事實 30,000 列｜維度累計 35,892 版本
  200507（第 3 近月）→ 事實 30,000 列｜維度累計 40,226 版本
  200508（第 2 近月）→ 事實 30,000 列｜維度累計 44,591 版本
  200509（第 1 近月）→ 事實 30,000 列｜維度累計 51,110 版本

✓ 所有 ERROR 級規則通過（8 條），3 條 WARN 如實標記來源髒資料
```

**重跑後筆數完全不變**（180,000 事實 / 51,110 版本）——ETL 一定會重跑，不可重跑的 ETL 等於每次故障都要人工清資料。

## SCD Type 2 是真的在運作

30,000 位客戶產生 51,110 個版本，代表風險等級發生了 21,110 次變更。抽一位驗證：

| 版本 | 風險等級 | 有效期間 |
|---|---|---|
| v1 | HIGH | 200504–200504 |
| v2 | LOW | 200505–200507 |
| v3 | HIGH | 200508–200508 |
| v4 | LOW | 200509–現行 |

而事實表接到的是**當月有效的版本**，不是最新版本：

| 月份 | 接到版本 | 當月繳款狀態 |
|---|---|---|
| 200504 | v1 (HIGH) | 延遲 2 個月 |
| 200505–07 | v2 (LOW) | 使用循環信用 |
| 200508 | v3 (HIGH) | 延遲 2 個月 |
| 200509 | v4 (LOW) | 按時繳清 |

**這是維度建模最常被做錯的地方**：事實表若一律 `JOIN ... WHERE is_current = 1`，歷史事實會全部指向最新版本，SCD Type 2 就白做了。正確寫法是把時點條件寫進 JOIN：

```sql
JOIN dw.dim_customer AS d
  ON d.client_id = s.client_id
 AND @date_key BETWEEN d.valid_from_date AND d.valid_to_date
```

版本數分布：16,598 位客戶從未變更、7,559 位變更 1 次、最多的變更 5 次。

## 星狀綱要讓這些問題變好問

`sql/05_analysis_queries.sql` 的四題，在原始寬表上每一題都得寫 UNPIVOT 或六段 UNION。

**風險等級遷移矩陣**——只有 SCD2 答得出來（維度若就地覆寫，歷史等級早就不存在）：

| 前月 → 本月 | LOW | MEDIUM | HIGH |
|---|---:|---:|---:|
| LOW | 90.0% | 5.8% | 4.1% |
| MEDIUM | 12.6% | 78.4% | 8.9% |
| HIGH | 19.0% | 14.9% | 66.1% |

**風險分層確實有鑑別力**（觀測期末等級 vs 次月違約）：

| 風險等級 | 客戶數 | 違約率 |
|---|---:|---:|
| HIGH | 3,130 | **69.6%** |
| MEDIUM | 8,151 | 24.3% |
| LOW | 18,719 | 13.2% |

**逾期率在觀測期內持續惡化**：10.3% → 22.7%（200504 → 200509）。

## 設計決策

**比率型量值存分子分母，不存比率。** 事實表存 `bill_amount` 與 `credit_limit`，不存 `utilization`。下游要算使用率時先各自加總再相除——直接對每列比率取平均會得到「平均的平均」，小額與大額帳戶被當成等權，結論會偏。

**碼值語意集中在維度表，且「文件定義」與「通行解讀」分欄。** `PAY_*` 是這份資料最有名的爭議欄位：官方文件只定義 −1 與 1–9，但實際資料大量出現 −2 與 0。學界慣例讀成「當期無消費」「使用循環信用」——**那是推論不是文件**。維度表兩者分欄，下游要嚴格依文件就只取 `documented_desc` 非空的列。

**未定義碼值不併進「其他」。** `EDUCATION` 實際出現 0/5/6（共 345 筆）、`MARRIAGE` 出現 0（54 筆），官方文件都沒定義。維度表如實登錄並標 `is_documented = 0`，靜靜併掉會讓資料字典的缺口永遠不被看見。

**SCD2 用 row_hash 而非逐欄比較。** 追蹤欄位增減時只要改雜湊組成，比較邏輯不動；逐欄 `OR` 比較在欄位變多時極易漏掉某一欄，而漏掉的後果是「該開版本卻沒開」——歷史從此靜默失真。雜湊前所有欄位一律 `ISNULL` 成哨兵值，否則 NULL 會讓整串雜湊變 NULL，使含 NULL 的列永遠被判定為已變更。

**ERROR 與 WARN 分野明確。** ERROR 是倉儲自身邏輯壞掉（粒度重複、孤兒鍵、版本重疊），必須修；WARN 是來源本來就長這樣（未定義碼值、帳單超額）。把來源髒資料判成 ERROR 會讓整條線每天紅燈，紅燈久了就沒人看——那比不檢核更糟。

**資料字典從系統目錄產出，不手寫。** 手寫的一定過期：欄位改了沒人記得改文件，久了就沒人信。`etl/gen_data_dictionary.py` 讀 `sys.tables` / `sys.columns` / `sys.foreign_key_columns`，文件與綱要不可能不一致。

## 環境備註：為什麼是 Azure SQL Edge 而不是 SQL Server 2022

原訂在 Apple Silicon 上以 amd64 模擬跑 `mcr.microsoft.com/mssql/server:2022-latest`，**實測會崩潰**：

```
Reason: 0x00000003  Status: 0x00000026
Message: Unable to create a new asynchronous I/O context. Please increase sysctl fs.aio-max-nr
```

錯誤訊息有誤導性——實際檢查 `fs.aio-max-nr` 已是上限 1,048,576，調高無效。真正原因是 Rosetta 對 `io_setup()` 的模擬不完整，這是 SQL Server 在 ARM Mac 的已知硬限制。

改用 **Azure SQL Edge（原生 arm64，SQL Server 2019 引擎）**，本專案用到的 T-SQL 全部支援：綱要、預存程序、`HASHBYTES`、篩選索引、視窗函數、`STRING_AGG`。

**誠實邊界**：Azure SQL Edge 是 SQL Server 的子集，**不含 SSIS**。本專案以 T-SQL 預存程序實作 ETL 邏輯——抽取、轉換、載入、批次控制、錯誤處理等概念相通，但 SSIS 是圖形化工具且僅 Windows，兩者不是同一個東西。

## 也在 AWS RDS for SQL Server 上跑過

同一套綱要與 ETL，**未改任何一行程式碼**，在 AWS RDS for SQL Server Express（SQL Server 2022）上完整跑完一次——連線參數本來就走環境變數，換環境只需換變數。基礎設施以 Terraform 定義（`infra/aws/`），流程是 **apply → 跑 ETL → 存證 → destroy**：這個專案不需要常駐，用完即銷毀，整趟成本在 US$1 以內。

實跑結果（`docs/evidence/`）：18 萬列事實、51,110 個 SCD Type 2 維度版本，9 條 ERROR 級品質規則全數通過，與本機容器一致。拆除後三項資源實查歸零。

```bash
cd infra/aws && terraform apply     # 約 15 分鐘
# 跑 ETL（見 docs/runbook-aws.md）
terraform destroy
```

搭配的最小權限 IAM 政策在 `infra/aws/iam-policy-terraform-rds.json`，兩個刻意的收斂：非指定區域的 API 一律 Deny，唯一的 IAM 寫入權限鎖死到 RDS 服務連結角色那一條路徑。完整操作與踩坑紀錄見 **[docs/runbook-aws.md](docs/runbook-aws.md)**。

**誠實邊界**：免費方案帳號只能開最小規格 `db.t3.micro`，而 t3 的 CPU 積分會在載入途中耗盡，吞吐從 250 列/秒掉到 13 列/秒——這趟 18 萬列實際跑了約 5 小時而非十幾分鐘。升級規格會被 `FreeTierRestrictionError` 擋下，需轉付費方案。這是機型與方案的限制，不是設定問題，但排程時要據實預留時間。

## 專案結構

```
infra/aws/                   Terraform：RDS、安全群組、子網路群組 + 最小權限 IAM 政策
docs/runbook-aws.md          雲端部署 runbook（開／跑／拆 + 已知踩點）
docs/evidence/               雲端實跑存證（ETL log、組態、驗證、拆除查核）
sql/01_schema.sql            綱要 DDL（含反依賴 teardown，可重複執行）
sql/02_reference_data.sql    參考維度種子 + 12 條品質規則登錄
sql/03_procedures.sql        SCD2 與事實載入預存程序
sql/04_quality_checks.sql    品質稽核程序 + 稽核／業務兩支檢視
sql/05_analysis_queries.sql  分析查詢範例
etl/db.py                    連線與 SQL 腳本執行（自行處理 GO 批次分隔）
etl/run_etl.py               編排：擷取 → 暫存 → 維度 → 事實 → 稽核
etl/gen_data_dictionary.py   從系統目錄產出資料字典
docs/data_dictionary.md      自動產出，勿手改
```

## 踩過的坑（保留在此，因為都是會再遇到的）

1. **`RULE` 是 T-SQL 保留字**（舊版 `CREATE RULE` 語法），`dq.rule` 建不起來。改名 `dq.quality_rule`——綱要設計避開保留字比事後加中括號可靠。
2. **DDL 可重複執行不是加 `IF EXISTS` 就好**：第一版沒有 teardown 段，腳本跑到一半失敗後，殘留的事實表就用外鍵擋住了維度表的 `DROP`，整份腳本再也跑不動。拆除順序必須反依賴。
3. **稽核的「樣本」欄要放摘要不是明細**：第一版用 `STRING_AGG` 串接每一列的碼值，三萬列瞬間爆掉 `NVARCHAR(400)`。
4. **`GO` 不是 T-SQL 語法**，是 sqlcmd 的批次分隔符。用程式送 SQL 時必須自己切批次，否則 `CREATE SCHEMA` 這類必須獨立成批的語句會失敗。
