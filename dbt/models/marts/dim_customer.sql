{{ config(
    materialized='table',
    cluster_by=['client_id'],
    description='客戶維度（SCD Type 2）。追蹤欄位＝risk_tier；BigQuery 版以視窗函數一次算完全部版本。'
) }}

/*
  SCD Type 2 —— 可攜性最大的一個看點。

  SQL Server 版（sql/03_procedures.sql）是**逐月程序式**：
    每個月呼叫一次 usp_load_dim_customer_scd2 →
      步驟 1 比對 row_hash，變了就把當前版本封版（valid_to = 前一個 date_key、is_current = 0）
      步驟 2 為新客戶或剛封版的客戶開新版本（valid_from = 本月、valid_to = 999912）
      步驟 3 Type 1 欄位就地覆寫
    月份順序錯了版本區間就錯——這是 Airflow DAG 要把六個月串成單鏈的原因。

  BigQuery 版是**一次掃描的集合式**：
    六個月的快照一起進來，用 LAG 找出 risk_tier 的變更點，
    每個變更點開一個版本，用 LEAD 補上區間結束。
    沒有迴圈、沒有 MERGE、也就沒有「月份順序」這個失敗模式——
    順序性被編碼在 ORDER BY 裡，而不是編碼在呼叫端。

  代價要誠實講：集合式版本**必須看得到全部歷史**才能算對區間。
  真實系統的增量載入（只到貨一個月）用這個寫法就得整表重算，
  資料量大時未必划算。這裡資料是固定的六個月快照，重算成本可忽略。

  代理鍵：T-SQL 用 IDENTITY（單調遞增、與內容無關），BigQuery 沒有 IDENTITY，
  改用 FARM_FINGERPRINT 對自然鍵＋生效日做確定性雜湊。
  這其實比 IDENTITY 好：**全量重建後代理鍵不變**，兩次跑出來的事實表可以逐列比對。
*/

with snap as (
    select
        client_id, date_key, source_month_ix,
        limit_bal, sex_code, education_code, marriage_code, age, age_band, risk_tier
    from {{ ref('stg_monthly_snapshot') }}
),

-- 由舊到新排序後標出「這個月的 risk_tier 與上個月不同」＝版本邊界。
-- source_month_ix 6 是最早月，所以排序用 ix 遞減。
flagged as (
    select
        *,
        lag(risk_tier) over (partition by client_id order by source_month_ix desc) as prev_tier
    from snap
),

version_starts as (
    select *
    from flagged
    where prev_tier is null or prev_tier <> risk_tier
),

versioned as (
    select
        client_id,
        limit_bal, sex_code, education_code, marriage_code, age, age_band, risk_tier,
        date_key as valid_from_date,
        -- 下一個版本的起始月 = 本版本的結束月；沒有下一版就是當前版本
        lead(date_key) over (partition by client_id order by source_month_ix desc) as next_from,
        row_number() over (partition by client_id order by source_month_ix desc)   as version_num
    from version_starts
)

select
    farm_fingerprint(format('%d|%d', client_id, valid_from_date)) as customer_sk,
    client_id,
    limit_bal,
    sex_code, education_code, marriage_code,
    age, age_band, risk_tier,
    valid_from_date,
    -- T-SQL 版封版時寫的是「前一個 date_key」；集合式這裡用「下一版的起始月」，
    -- 兩者是同一個區間的兩種端點慣例。對帳查詢（analyses/）比的是
    -- **每個客戶每個月落在哪一版**，而不是端點數字本身——那才是語意等價的檢驗。
    coalesce(next_from, 999912) as valid_to_date,
    next_from is null           as is_current,
    version_num
from versioned
