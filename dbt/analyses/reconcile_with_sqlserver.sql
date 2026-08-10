/*
  跨引擎對帳：BigQuery 版與 SQL Server 版必須算出同一份倉儲。

  用法：在 BigQuery 跑這支查詢，把結果與 SQL Server 版的同名查詢
  （sql/05_analysis_queries.sql 之外另附於 docs/runbook-gcp.md）逐列比對。

  **比什麼，比不比什麼**
  - 比：列數、SCD2 版本數、每個客戶每個月落在哪一個 risk_tier 版本、
        風險分層的違約率。這些是語意，兩邊必須一致。
  - 不比：代理鍵的值（一邊 IDENTITY、一邊 FARM_FINGERPRINT，本來就不同）、
        valid_to_date 的端點慣例（封版寫「前一月」vs「下一版起始月」）。
        比這些只會比出「實作不同」——那是已知的，不是要驗的東西。

  這個分野本身就是可攜性的重點：**可攜的是語意，不是實作**。
*/

with counts as (
    select 'fact_monthly_statement' as obj, count(*) as n from {{ ref('fact_monthly_statement') }}
    union all select 'fact_default_outcome', count(*) from {{ ref('fact_default_outcome') }}
    union all select 'dim_customer_versions', count(*) from {{ ref('dim_customer') }}
    union all select 'dim_customer_naturals', count(distinct client_id) from {{ ref('dim_customer') }}
),

-- 每個客戶每個月的有效版本落在哪一個 risk_tier：這是 SCD2 的語意本體
tier_by_month as (
    select f.date_key, c.risk_tier, count(*) as n
    from {{ ref('fact_monthly_statement') }} as f
    join {{ ref('dim_customer') }} as c using (customer_sk)
    group by 1, 2
),

-- 風險分層的鑑別力：README 引用的 HIGH 69.6% vs LOW 13.2% 必須在兩邊一致
tier_default_rate as (
    select
        c.risk_tier,
        count(*) as customers,
        round(avg(o.is_default) * 100, 1) as default_rate_pct
    from {{ ref('fact_default_outcome') }} as o
    join {{ ref('dim_customer') }} as c
      on c.client_id = o.client_id and c.is_current
    group by 1
)

select 'count' as section, obj as k1, cast(n as string) as k2, null as k3 from counts
union all
select 'tier_by_month', cast(date_key as string), risk_tier, cast(n as string) from tier_by_month
union all
select 'tier_default_rate', risk_tier, cast(customers as string), cast(default_rate_pct as string)
from tier_default_rate
order by section, k1, k2
