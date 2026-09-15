/*
  同庫對帳：dbt 版（dbt_dw／dbt_stg）vs 預存程序版（dw／stg）。

  跨引擎對帳（reconcile_with_sqlserver.sql）要把查詢結果搬到同一邊才能比；
  edge target 的特權是兩套實作落在同一個資料庫——對帳就是幾個 JOIN，
  沒有匯出、沒有浮點序列化、沒有「差異是不是搬運造成的」這層懷疑。

  比什麼、不比什麼：
    1. 列數三件組：事實 180,000、維度版本 51,110、結果 30,000。
    2. SCD2 語意：**每個客戶每個月落在哪一版（risk_tier）**——這才是語意等價的檢驗；
       版本端點的數字慣例兩邊本來就不同（見 dim_customer.sql 的註解）。
    3. 事實量值：逐月 bill／payment 總額逐一相等。
    4. 不比代理鍵：IDENTITY 與 HASHBYTES 本來就不同，比了只會製造假警報。

  預期輸出：三個查詢全部零列（差異列）＋一列總結。
*/

-- 1. 列數三件組（有差異才回列）
select 'rowcount' as check_name, t.name, t.dbt_n, t.proc_n
from (
    select 'fact_monthly_statement' as name,
           (select count(*) from dbt_dw.fact_monthly_statement) as dbt_n,
           (select count(*) from dw.fact_monthly_statement)     as proc_n
    union all
    select 'dim_customer_versions',
           (select count(*) from dbt_dw.dim_customer),
           (select count(*) from dw.dim_customer)
    union all
    select 'fact_default_outcome',
           (select count(*) from dbt_dw.fact_default_outcome),
           (select count(*) from dw.fact_default_outcome)
) as t
where t.dbt_n <> t.proc_n;

-- 2. SCD2 語意：每客戶每月的有效版本 risk_tier 必須兩邊一致
with months as (select distinct date_key from dbt_dw.dim_date where source_month_ix between 1 and 6),
dbt_at as (
    select m.date_key, d.client_id, d.risk_tier
    from months as m
    join dbt_dw.dim_customer as d
      on m.date_key >= d.valid_from_date and m.date_key < d.valid_to_date
),
proc_at as (
    -- 端點慣例不同：預存程序版封版寫的是「本版本適用的最後一個月」（含端），
    -- dbt 版寫的是「下一版的起始月」（排他端）。對帳必須各用各的述詞，
    -- 語意才對得起來——直接抄同一個述詞就會憑空多出 21,110 列假差異
    -- （恰好等於非當前版本數，每個被封的版本掉最後一個月）。
    select m.date_key, d.client_id, d.risk_tier
    from months as m
    join dw.dim_customer as d
      on m.date_key >= d.valid_from_date and m.date_key <= d.valid_to_date
)
select a.client_id, a.date_key, a.risk_tier as dbt_tier, b.risk_tier as proc_tier
from dbt_at as a
full outer join proc_at as b
  on a.client_id = b.client_id and a.date_key = b.date_key
where a.risk_tier <> b.risk_tier
   or a.client_id is null or b.client_id is null;

-- 3. 逐月量值總額
select a.date_key,
       a.bill_sum  as dbt_bill,  b.bill_sum  as proc_bill,
       a.pay_sum   as dbt_pay,   b.pay_sum   as proc_pay
from (select date_key, sum(bill_amount) as bill_sum, sum(payment_amount) as pay_sum
      from dbt_dw.fact_monthly_statement group by date_key) as a
join (select date_key, sum(bill_amount) as bill_sum, sum(payment_amount) as pay_sum
      from dw.fact_monthly_statement group by date_key) as b
  on a.date_key = b.date_key
where a.bill_sum <> b.bill_sum or a.pay_sum <> b.pay_sum;
