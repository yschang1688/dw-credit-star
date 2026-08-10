{{ config(
    materialized='table',
    cluster_by=['client_id'],
    description='違約結果事實。粒度：一個客戶一列——與帳單事實分開，否則違約旗標會被重複計算六次。'
) }}

/*
  粒度不同的事實必須分表。這在 SQL Server 版與這裡是同一個決定，
  也是星狀綱要最常被違反的規則：把「一客戶一列」的結果欄塞進
  「一客戶一月一列」的事實表，SUM 出來的違約數就是實際的六倍，
  而且沒有任何錯誤訊息。

  結果月：觀測期結束後的次月（source_month_ix = 7，即 200510）。
  維度關聯取觀測期最後一個月的有效版本——違約發生在觀測期之後，
  當時「客戶是什麼等級」才是放款覆核要問的問題。
*/

with last_observed as (
    select client_id, max(date_key) as last_date_key
    from {{ ref('stg_monthly_snapshot') }}
    group by client_id
),

outcome as (
    select distinct client_id, default_next_month
    from {{ ref('stg_monthly_snapshot') }}
)

select
    farm_fingerprint(format('%d|outcome', o.client_id)) as outcome_sk,
    c.customer_sk,
    (select date_key from {{ ref('dim_date') }} where source_month_ix = 7) as date_key,
    o.client_id,
    o.default_next_month as is_default
from outcome as o
join last_observed as l using (client_id)
join {{ ref('dim_customer') }} as c
  on  c.client_id = o.client_id
  and l.last_date_key >= c.valid_from_date
  and l.last_date_key <  c.valid_to_date
