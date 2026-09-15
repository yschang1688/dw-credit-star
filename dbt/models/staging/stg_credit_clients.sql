{{ config(materialized='view') }}

-- 來源寬表的薄封裝：只做欄名正規化與型別收斂，不做任何業務轉換。
-- 「暫存層不轉換」是 Kimball 的分層紀律——轉換混進落地層，
-- 出問題時就分不清是來源髒還是自己弄髒的。
select
    cast(client_id as bigint)            as client_id,
    cast(limit_bal as numeric(12,2))          as limit_bal,
    cast(sex as bigint)                  as sex_code,
    cast(education as bigint)            as education_code,
    cast(marriage as bigint)             as marriage_code,
    cast(age as bigint)                  as age,
    {% for i in range(1, 7) %}
    cast(pay_{{ i }} as bigint)          as pay_{{ i }},
    cast(bill_amt{{ i }} as numeric(14,2))    as bill_amt{{ i }},
    cast(pay_amt{{ i }} as numeric(14,2))     as pay_amt{{ i }}{{ "," if not loop.last }}
    {% endfor %},
    cast(default_next_month as bigint)   as default_next_month
from {{ source('raw', 'credit_clients') }}
