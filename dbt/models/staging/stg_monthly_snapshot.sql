{{ config(materialized='view') }}

/*
  把寬表攤平成「客戶 × 月份」的長格式——這是整個倉儲的軸心轉換。

  與 SQL Server 版的差異（可攜性的第一個看點）：
    T-SQL 版在預存程序裡用 `CROSS APPLY` + `CASE @month_ix` 每次處理一個月，
    因為 SCD2 本來就要逐月推進。BigQuery 是欄式且不鼓勵逐列迴圈，
    這裡改成一次 UNPIVOT 全部六個月，後續 SCD2 用視窗函數一次算完。
    **語意相同、執行形態相反**：一邊是六次程序呼叫，一邊是一次掃描。

  月份對映沿用資料字典：source_month_ix 1=最近月(200509) … 6=最早月(200504)。
*/
with unpivoted as (
    {% for i in range(1, 7) %}
    select
        client_id,
        {{ i }}         as source_month_ix,
        pay_{{ i }}     as pay_status_code,
        bill_amt{{ i }} as bill_amount,
        pay_amt{{ i }}  as payment_amount,
        limit_bal,
        sex_code, education_code, marriage_code, age,
        default_next_month
    from {{ ref('stg_credit_clients') }}
    {{ "union all" if not loop.last }}
    {% endfor %}
)
select
    u.*,
    d.date_key,
    -- 風險等級：與 T-SQL 版 usp_load_dim_customer_scd2 的 CASE 完全同義。
    -- 兩邊各寫一次是刻意的——共用一份會需要跨引擎的 UDF，
    -- 那是把可攜性問題換成另一個可攜性問題。差異靠 analyses/ 的對帳查詢驗。
    case
        when u.pay_status_code >= 2 then 'HIGH'
        when u.pay_status_code = 1
             or (u.limit_bal > 0 and {{ safe_div('u.bill_amount', 'u.limit_bal') }} > 0.90) then 'MEDIUM'
        else 'LOW'
    end as risk_tier,
    case
        when u.age < 30 then '20-29'
        when u.age < 40 then '30-39'
        when u.age < 50 then '40-49'
        when u.age < 60 then '50-59'
        else '60+'
    end as age_band
from unpivoted as u
join {{ ref('dim_date') }} as d on d.source_month_ix = u.source_month_ix
