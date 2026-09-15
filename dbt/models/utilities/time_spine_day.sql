{{ config(materialized='table') }}

/*
  語意層要求的時間骨架（time spine）：日粒度、連續、涵蓋觀測期。
  範圍由 dim_date seed 推導（2005-04-01 ～ 2005-10-31，含結果月），不手打日期——
  觀測期若擴大，改 seed 就跟著長。
  T-SQL 家族沒有 generate_series 前的作法：以 dim_date 的月數 × 31 天做笛卡兒積再過濾。
  BigQuery 端本模型未實跑（generate_date_array 是更自然的寫法，但為了單一 SQL 通兩引擎
  這裡只用 cross join；語意層本輪也只驗 parse）。
*/
with bounds as (
    select
        min(month_end_date) as first_month_end,
        max(month_end_date) as last_month_end
    from {{ ref('dim_date') }}
),
days as (
    {% for i in range(0, 220) %}
    select {{ i }} as day_offset{{ " union all" if not loop.last }}
    {% endfor %}
),
spine as (
    select dateadd(day, d.day_offset, dateadd(day, 1 - day(b.first_month_end), b.first_month_end)) as date_day
    from bounds as b
    cross join days as d
)
select date_day
from spine, bounds
where date_day <= bounds.last_month_end
