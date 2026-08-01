/*  ETL 預存程序
    ---------------------------------------------------------------
    分三支：客戶維度（SCD Type 2）、月度事實、違約結果。
    共同原則：**每支都可重跑**。ETL 一定會重跑——來源補送、下游發現錯誤、
    排程重試——不可重跑的 ETL 等於每次故障都要人工清資料。
*/
USE CreditRiskDW;
GO

/* ═══════════════════════════════════════════════════════════════
   dw.usp_load_dim_customer_scd2
   ---------------------------------------------------------------
   把某一個月的客戶快照併入客戶維度，以 SCD Type 2 保留歷史。

   追蹤欄位（變更即開新版本）：risk_tier
   非追蹤欄位（變更就地覆寫，屬 Type 1）：age_band 等描述性欄位

   為什麼用 row_hash 而不是逐欄比較：追蹤欄位增減時只要改雜湊的組成，
   比較邏輯不用動；逐欄 `OR` 比較在欄位變多時極易漏掉某一欄，
   而漏掉的後果是「該開版本卻沒開」——歷史從此靜默失真。

   NULL 的處理：雜湊前一律 ISNULL 成哨兵值，否則 NULL 會讓整串雜湊變 NULL，
   使得「有 NULL 的列」永遠被判定為已變更。
   ═══════════════════════════════════════════════════════════════ */
CREATE OR ALTER PROCEDURE dw.usp_load_dim_customer_scd2
    @date_key      INT,
    @load_batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;                 -- 任何錯誤即整批回捲，不留半套資料

    DECLARE @month_ix TINYINT = (SELECT source_month_ix FROM dw.dim_date WHERE date_key = @date_key);
    IF @month_ix IS NULL
    BEGIN
        RAISERROR(N'date_key %d 不存在於 dw.dim_date', 16, 1, @date_key);
        RETURN;
    END

    BEGIN TRAN;

    /*  當月客戶快照。
        risk_tier 由當月繳款狀態與額度使用率導出——這是本維度會隨月變動的原因。
        誠實說明：來源的信用額度是單一時點值、不隨月變動，
        所以不能假造額度變更史；風險等級才是真正可從資料導出的變化。 */
    WITH snapshot AS (
        SELECT
            s.client_id,
            s.limit_bal,
            sx.sex_key,
            ed.education_key,
            mr.marriage_key,
            s.age,
            CASE
                WHEN s.age < 30 THEN N'20-29'
                WHEN s.age < 40 THEN N'30-39'
                WHEN s.age < 50 THEN N'40-49'
                WHEN s.age < 60 THEN N'50-59'
                ELSE N'60+'
            END AS age_band,
            CASE
                WHEN pay_status.code >= 2 THEN N'HIGH'
                WHEN pay_status.code = 1
                     OR (s.limit_bal > 0 AND bill.amt / s.limit_bal > 0.90) THEN N'MEDIUM'
                ELSE N'LOW'
            END AS risk_tier
        FROM stg.credit_clients AS s
        CROSS APPLY (SELECT CASE @month_ix
                                WHEN 1 THEN s.pay_1 WHEN 2 THEN s.pay_2 WHEN 3 THEN s.pay_3
                                WHEN 4 THEN s.pay_4 WHEN 5 THEN s.pay_5 ELSE s.pay_6 END AS code) AS pay_status
        CROSS APPLY (SELECT CASE @month_ix
                                WHEN 1 THEN s.bill_amt1 WHEN 2 THEN s.bill_amt2 WHEN 3 THEN s.bill_amt3
                                WHEN 4 THEN s.bill_amt4 WHEN 5 THEN s.bill_amt5 ELSE s.bill_amt6 END AS amt) AS bill
        JOIN dw.dim_sex       AS sx ON sx.sex_code       = s.sex
        JOIN dw.dim_education AS ed ON ed.education_code = s.education
        JOIN dw.dim_marriage  AS mr ON mr.marriage_code  = s.marriage
        WHERE s.load_batch_id = @load_batch_id
    ),
    hashed AS (
        SELECT *,
               HASHBYTES('SHA2_256',
                    CONCAT(ISNULL(risk_tier, N'~'), N'|',
                           ISNULL(CONVERT(NVARCHAR(30), limit_bal), N'~'))
               ) AS row_hash
        FROM snapshot
    )
    SELECT * INTO #snap FROM hashed;

    /*  步驟 1：封版。
        當前版本存在、但追蹤欄位雜湊已改變者，把有效期間關到本月之前。
        valid_to 設為「本月的前一個 date_key」——用 dim_date 取，不做字串運算，
        因為跨年時 yyyymm 減一會得到 yyyy00 這種不存在的鍵。 */
    DECLARE @prev_date_key INT = (
        SELECT TOP 1 date_key FROM dw.dim_date
        WHERE date_key < @date_key ORDER BY date_key DESC);

    UPDATE d
       SET d.valid_to_date = ISNULL(@prev_date_key, @date_key),
           d.is_current    = 0
      FROM dw.dim_customer AS d
      JOIN #snap AS s ON s.client_id = d.client_id
     WHERE d.is_current = 1
       AND d.row_hash <> s.row_hash;

    /*  步驟 2：開新版本。
        兩種情況：全新客戶，或剛被封版的客戶。 */
    INSERT INTO dw.dim_customer
        (client_id, limit_bal, sex_key, education_key, marriage_key, age, age_band,
         risk_tier, valid_from_date, valid_to_date, is_current, version_num, row_hash)
    SELECT
        s.client_id, s.limit_bal, s.sex_key, s.education_key, s.marriage_key, s.age, s.age_band,
        s.risk_tier, @date_key, 999912, 1,
        ISNULL((SELECT MAX(version_num) FROM dw.dim_customer c WHERE c.client_id = s.client_id), 0) + 1,
        s.row_hash
    FROM #snap AS s
    WHERE NOT EXISTS (
        SELECT 1 FROM dw.dim_customer AS d
         WHERE d.client_id = s.client_id AND d.is_current = 1);

    /*  步驟 3：Type 1 欄位就地更新（描述性欄位不需保留歷史）。 */
    UPDATE d
       SET d.age = s.age, d.age_band = s.age_band
      FROM dw.dim_customer AS d
      JOIN #snap AS s ON s.client_id = d.client_id
     WHERE d.is_current = 1 AND (d.age <> s.age OR d.age_band <> s.age_band);

    DROP TABLE #snap;
    COMMIT;
END
GO

/* ═══════════════════════════════════════════════════════════════
   dw.usp_load_fact_monthly_statement
   ---------------------------------------------------------------
   把寬表的某一個月攤平成事實列。

   關鍵：關聯到**當月有效**的客戶維度版本，不是當前版本。
   若一律接 is_current=1，歷史事實會全部指向最新版本，
   SCD Type 2 就白做了——這是維度建模最常見的實作錯誤。
   ═══════════════════════════════════════════════════════════════ */
CREATE OR ALTER PROCEDURE dw.usp_load_fact_monthly_statement
    @date_key      INT,
    @load_batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @month_ix TINYINT = (SELECT source_month_ix FROM dw.dim_date WHERE date_key = @date_key);

    BEGIN TRAN;

    -- 可重跑：先清掉本月既有事實，再重建
    DELETE FROM dw.fact_monthly_statement WHERE date_key = @date_key;

    INSERT INTO dw.fact_monthly_statement
        (customer_sk, date_key, pay_status_key, client_id,
         bill_amount, payment_amount, credit_limit, load_batch_id)
    SELECT
        d.customer_sk,
        @date_key,
        ps.pay_status_key,
        s.client_id,
        bill.amt,
        pay.amt,
        s.limit_bal,
        @load_batch_id
    FROM stg.credit_clients AS s
    CROSS APPLY (SELECT CASE @month_ix
                            WHEN 1 THEN s.bill_amt1 WHEN 2 THEN s.bill_amt2 WHEN 3 THEN s.bill_amt3
                            WHEN 4 THEN s.bill_amt4 WHEN 5 THEN s.bill_amt5 ELSE s.bill_amt6 END AS amt) AS bill
    CROSS APPLY (SELECT CASE @month_ix
                            WHEN 1 THEN s.pay_amt1 WHEN 2 THEN s.pay_amt2 WHEN 3 THEN s.pay_amt3
                            WHEN 4 THEN s.pay_amt4 WHEN 5 THEN s.pay_amt5 ELSE s.pay_amt6 END AS amt) AS pay
    CROSS APPLY (SELECT CASE @month_ix
                            WHEN 1 THEN s.pay_1 WHEN 2 THEN s.pay_2 WHEN 3 THEN s.pay_3
                            WHEN 4 THEN s.pay_4 WHEN 5 THEN s.pay_5 ELSE s.pay_6 END AS code) AS pay_st
    JOIN dw.dim_payment_status AS ps ON ps.pay_status_code = pay_st.code
    -- ★ 時點正確的維度關聯：取當月落在有效期間內的那個版本
    JOIN dw.dim_customer AS d
      ON d.client_id       = s.client_id
     AND @date_key        >= d.valid_from_date
     AND @date_key        <= d.valid_to_date
    WHERE s.load_batch_id = @load_batch_id;

    COMMIT;
END
GO

/* ═══════════════════════════════════════════════════════════════
   dw.usp_load_fact_default_outcome
   粒度：一位客戶一列。與月度事實分表，避免違約旗標被重複計六次。
   ═══════════════════════════════════════════════════════════════ */
CREATE OR ALTER PROCEDURE dw.usp_load_fact_default_outcome
    @date_key      INT,
    @load_batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;
    DELETE FROM dw.fact_default_outcome;

    INSERT INTO dw.fact_default_outcome (customer_sk, date_key, client_id, is_default, load_batch_id)
    SELECT d.customer_sk, @date_key, s.client_id, s.default_next_month, @load_batch_id
    FROM stg.credit_clients AS s
    JOIN dw.dim_customer AS d
      ON d.client_id = s.client_id AND d.is_current = 1   -- 結果掛在最新版本
    WHERE s.load_batch_id = @load_batch_id;

    COMMIT;
END
GO

PRINT 'ETL 預存程序建立完成';
GO
