{{ config(
    materialized='table',
    partition_by={'field': 'date_key', 'data_type': 'int64',
                  'range': {'start': 200504, 'end': 200510, 'interval': 1}},
    cluster_by=['client_id'],
    description='月度帳單事實。粒度：一個客戶 × 一個月 = 一列（30,000 × 6 = 180,000）。'
) }}

/*
  分區與叢集：SQL Server 版用「date_key 索引 + INCLUDE 量值欄」讓月度查詢不回表；
  BigQuery 沒有索引這個東西，對應物是**分區裁剪 + 叢集**。
  這裡用 range 分區（date_key 是 yyyymm 整數）而非日期分區——
  yyyymm 不是連續整數（200509 的下一個是 200510，但 200512 的下一個是 200601），
  所以 interval=1 會產生一些空分區，這是刻意接受的代價：
  改成真日期欄位就得動綱要，而綱要要跟 SQL Server 版對得起來。

  時點正確的維度關聯（本專案最核心的正確性要求）：
  事實列必須接到**當月有效**的維度版本，不是當前版本。
  T-SQL 版寫在 JOIN 的時序述詞裡；這裡同理——用 valid_from/valid_to 夾住 date_key，
  絕不能寫成 `where is_current`（那會把全部歷史指向最新版本，而且不會報錯）。
*/

select
    {{ hash_sk(['s.client_id', 's.date_key']) }} as statement_sk,
    c.customer_sk,
    s.date_key,
    s.pay_status_code,
    s.client_id,                    -- 退化維度：便於稽核回溯來源
    s.bill_amount,
    s.payment_amount,
    s.limit_bal as credit_limit     -- 非可加總比率的分母：存分子分母，不存比率
from {{ ref('stg_monthly_snapshot') }} as s
join {{ ref('dim_customer') }} as c
  on  c.client_id = s.client_id
  and s.date_key >= c.valid_from_date
  and s.date_key <  c.valid_to_date
