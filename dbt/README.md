# dbt（BigQuery）——同一份倉儲的第三種實作

這不是「把 T-SQL 翻成 BigQuery SQL」，是把**同一份倉儲重新表達**。
為什麼要重新表達、什麼准變什麼不准變，見 [`docs/runbook-gcp.md`](../docs/runbook-gcp.md)。

| 你想看 | 去這裡 |
|---|---|
| SCD2 從逐月程序改成一次視窗運算 | [`models/marts/dim_customer.sql`](models/marts/dim_customer.sql) |
| 寬表攤平（T-SQL 逐月 vs 這裡一次 UNPIVOT） | [`models/staging/stg_monthly_snapshot.sql`](models/staging/stg_monthly_snapshot.sql) |
| 索引的對應物：分區與叢集 | [`models/marts/fact_monthly_statement.sql`](models/marts/fact_monthly_statement.sql) |
| 12 條品質規則的 dbt 版 | [`macros/tests.sql`](macros/tests.sql)＋[`models/marts/_marts.yml`](models/marts/_marts.yml) |
| 跨引擎對帳查詢 | [`analyses/reconcile_with_sqlserver.sql`](analyses/reconcile_with_sqlserver.sql) |

**刻意不裝 dbt_utils／dbt_expectations**：那兩個套件要 `dbt deps` 拉網路，
而本專案的賣點之一是完整重現——多一層網路相依就多一個「別人跑不起來」的理由。
需要的四個通用測試自己寫，不到 40 行。
