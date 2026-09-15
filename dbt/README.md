# dbt——同一份倉儲的第三種實作（多引擎）

這不是「把 T-SQL 翻成 BigQuery SQL」，是把**同一份倉儲重新表達**。
為什麼要重新表達、什麼准變什麼不准變，見 [`docs/runbook-gcp.md`](../docs/runbook-gcp.md)。

同一份模型與測試，兩個 target：

| target | 引擎 | 用途 | 實跑存證 |
|---|---|---|---|
| `sandbox` | BigQuery（Sandbox） | 欄式引擎對照組：UNPIVOT、視窗式 SCD2、分區叢集 | [`docs/evidence/gcp/`](../docs/evidence/gcp/run.md) |
| `edge` | Azure SQL Edge（本機容器） | **T-SQL 方言驗證**：與預存程序版同庫並存、同庫對帳 | [`docs/evidence/dbt-edge/`](../docs/evidence/dbt-edge/run.md) |

引擎方言差異全部收在 [`macros/cross_db.sql`](macros/cross_db.sql)：模型檔裡不出現任何
引擎專屬函數，代理鍵雜湊、安全除法、真值旗標走 `adapter.dispatch`。`default__` 實作
一律寫 T-SQL——dbt-sqlserver、**dbt-fabric**（Microsoft Fabric Warehouse）、dbt-synapse
講的是同一種方言，都落到同一份 `default__`。在 `edge` 上跑通的 44 個節點
（5 seeds＋5 模型＋34 測試），接 Fabric 只差在 `profiles.yml` 換一個 target。

```bash
# T-SQL target：先照根目錄 quickstart 起容器並跑 ETL（dbt 讀它落地的 stg.credit_clients）
cd dbt && DBT_PROFILES_DIR=. dbt build --target edge      # 44 節點約 100 秒全綠
DBT_PROFILES_DIR=. dbt docs generate --target edge        # 血緣圖＋逐欄文件
```

| 你想看 | 去這裡 |
|---|---|
| SCD2 從逐月程序改成一次視窗運算 | [`models/marts/dim_customer.sql`](models/marts/dim_customer.sql) |
| 寬表攤平（T-SQL 逐月 vs 這裡一次 UNPIVOT） | [`models/staging/stg_monthly_snapshot.sql`](models/staging/stg_monthly_snapshot.sql) |
| 索引的對應物：分區與叢集 | [`models/marts/fact_monthly_statement.sql`](models/marts/fact_monthly_statement.sql) |
| 12 條品質規則的 dbt 版 | [`macros/tests.sql`](macros/tests.sql)＋[`models/marts/_marts.yml`](models/marts/_marts.yml) |
| 跨引擎對帳查詢（BigQuery vs SQL Server） | [`analyses/reconcile_with_sqlserver.sql`](analyses/reconcile_with_sqlserver.sql) |
| 同庫對帳查詢（dbt 版 vs 預存程序版，含端點慣例陷阱） | [`analyses/reconcile_edge_dbt_vs_procs.sql`](analyses/reconcile_edge_dbt_vs_procs.sql) |
| 方言差異的唯一集中點（Fabric-ready 的機制） | [`macros/cross_db.sql`](macros/cross_db.sql) |

**刻意不裝 dbt_utils／dbt_expectations**：那兩個套件要 `dbt deps` 拉網路，
而本專案的賣點之一是完整重現——多一層網路相依就多一個「別人跑不起來」的理由。
需要的四個通用測試自己寫，不到 40 行。
