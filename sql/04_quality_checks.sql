/*  資料品質稽核
    ---------------------------------------------------------------
    立場：品質檢核是 ETL 的一部分，不是事後的報表。
    每條規則把「檢了幾列、幾列失敗、失敗長什麼樣」寫進 dq.quality_result，
    讓「這批資料當時的品質」可回溯——只印在終端機的檢核等於沒做。

    ERROR 與 WARN 的分野：
      ERROR 代表倉儲自身邏輯壞掉（粒度重複、孤兒鍵、版本重疊），必須修
      WARN  代表來源資料本來就長這樣（未定義碼值、負數繳款），要標記但不阻擋
    把來源的髒資料判成 ERROR 會讓整條線每天紅燈，紅燈久了就沒人看——
    這比不檢核更糟。
*/
USE CreditRiskDW;
GO

CREATE OR ALTER PROCEDURE dq.usp_run_quality_checks
    @load_batch_id  UNIQUEIDENTIFIER,
    @expected_rows  INT
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dq.quality_result WHERE load_batch_id = @load_batch_id;

    DECLARE @months INT = (SELECT COUNT(*) FROM dw.dim_date WHERE source_month_ix BETWEEN 1 AND 6);

    /* 1 暫存區筆數 */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 1, @load_batch_id, COUNT(*),
           CASE WHEN COUNT(*) = @expected_rows THEN 0 ELSE ABS(COUNT(*) - @expected_rows) END,
           CONCAT(N'來源 ', @expected_rows, N' 列，暫存區 ', COUNT(*), N' 列')
    FROM stg.credit_clients WHERE load_batch_id = @load_batch_id;

    /* 2 暫存區主鍵唯一 */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 2, @load_batch_id,
           (SELECT COUNT(*) FROM stg.credit_clients WHERE load_batch_id = @load_batch_id),
           ISNULL(SUM(dup.extra), 0),
           CONCAT(N'重複 client_id 數：', ISNULL(COUNT(*), 0))
    FROM (SELECT client_id, COUNT(*) - 1 AS extra
            FROM stg.credit_clients WHERE load_batch_id = @load_batch_id
           GROUP BY client_id HAVING COUNT(*) > 1) AS dup;

    /* 3 教育程度未定義碼值（WARN：來源本來就有） */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 3, @load_batch_id, COUNT(*),
           SUM(CASE WHEN e.is_documented = 0 THEN 1 ELSE 0 END),
           -- 樣本欄要放「摘要」不是「明細」：第一版直接 STRING_AGG 每一列的碼值，
           -- 三萬列串起來立刻爆掉 NVARCHAR(400)。摘要才是稽核報表要的東西。
           (SELECT CONCAT(N'未定義碼值分布：', STRING_AGG(x.txt, N'　'))
              FROM (SELECT CONCAT(N'碼', e2.education_code, N'=', COUNT(*), N'筆') AS txt
                      FROM dw.dim_customer AS d2
                      JOIN dw.dim_education AS e2 ON e2.education_key = d2.education_key
                     WHERE d2.is_current = 1 AND e2.is_documented = 0
                     GROUP BY e2.education_code) AS x)
    FROM dw.dim_customer AS d
    JOIN dw.dim_education AS e ON e.education_key = d.education_key
    WHERE d.is_current = 1;

    /* 4 婚姻狀況未定義碼值 */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 4, @load_batch_id, COUNT(*),
           SUM(CASE WHEN m.is_documented = 0 THEN 1 ELSE 0 END),
           CONCAT(N'未定義碼值筆數：', SUM(CASE WHEN m.is_documented = 0 THEN 1 ELSE 0 END))
    FROM dw.dim_customer AS d
    JOIN dw.dim_marriage AS m ON m.marriage_key = d.marriage_key
    WHERE d.is_current = 1;

    /* 5 事實表粒度 */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 5, @load_batch_id,
           (SELECT COUNT(*) FROM dw.fact_monthly_statement),
           ISNULL(SUM(g.extra), 0),
           CONCAT(N'違反粒度的組合數：', ISNULL(COUNT(*), 0))
    FROM (SELECT client_id, date_key, COUNT(*) - 1 AS extra
            FROM dw.fact_monthly_statement
           GROUP BY client_id, date_key HAVING COUNT(*) > 1) AS g;

    /* 6 孤兒外鍵 */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 6, @load_batch_id, COUNT(*),
           SUM(CASE WHEN d.customer_sk IS NULL THEN 1 ELSE 0 END),
           N'孤兒 customer_sk 筆數'
    FROM dw.fact_monthly_statement AS f
    LEFT JOIN dw.dim_customer AS d ON d.customer_sk = f.customer_sk;

    /* 7 事實筆數 = 客戶數 × 月份數 */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 7, @load_batch_id, COUNT(*),
           ABS(COUNT(*) - (@expected_rows * @months)),
           CONCAT(N'預期 ', @expected_rows * @months, N' 列，實際 ', COUNT(*), N' 列')
    FROM dw.fact_monthly_statement;

    /* 8 SCD2 版本區間不得重疊 */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 8, @load_batch_id,
           (SELECT COUNT(*) FROM dw.dim_customer),
           ISNULL(COUNT(*), 0),
           CONCAT(N'重疊版本組數：', ISNULL(COUNT(*), 0))
    FROM dw.dim_customer AS a
    JOIN dw.dim_customer AS b
      ON b.client_id = a.client_id AND b.customer_sk > a.customer_sk
     AND a.valid_from_date <= b.valid_to_date
     AND b.valid_from_date <= a.valid_to_date;

    /* 9 每位客戶恰有一筆當前版本 */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 9, @load_batch_id,
           (SELECT COUNT(DISTINCT client_id) FROM dw.dim_customer),
           ISNULL(COUNT(*), 0),
           CONCAT(N'當前版本數 <> 1 的客戶數：', ISNULL(COUNT(*), 0))
    FROM (SELECT client_id FROM dw.dim_customer
           GROUP BY client_id HAVING SUM(CONVERT(INT, is_current)) <> 1) AS bad;

    /* 10 負數繳款（WARN） */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 10, @load_batch_id, COUNT(*),
           SUM(CASE WHEN payment_amount < 0 THEN 1 ELSE 0 END),
           CONCAT(N'最小繳款金額：', MIN(payment_amount))
    FROM dw.fact_monthly_statement;

    /* 11 帳單超過額度（WARN） */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 11, @load_batch_id, COUNT(*),
           SUM(CASE WHEN bill_amount > credit_limit THEN 1 ELSE 0 END),
           CONCAT(N'最大超額比：',
                  CONVERT(NVARCHAR(20), ROUND(MAX(CASE WHEN credit_limit > 0
                        THEN bill_amount / credit_limit END), 2)))
    FROM dw.fact_monthly_statement;

    /* 12 違約結果覆蓋率 */
    INSERT INTO dq.quality_result (rule_id, load_batch_id, rows_checked, rows_failed, sample_detail)
    SELECT 12, @load_batch_id, @expected_rows,
           ABS(@expected_rows - COUNT(*)),
           CONCAT(N'違約結果列數：', COUNT(*))
    FROM dw.fact_default_outcome;
END
GO

/*  稽核報表檢視：一眼看出哪些規則沒過、嚴重度為何。 */
CREATE OR ALTER VIEW dq.v_quality_report AS
SELECT
    r.rule_code,
    r.severity,
    r.target_object,
    res.rows_checked,
    res.rows_failed,
    CASE WHEN res.rows_failed = 0 THEN N'PASS'
         WHEN r.severity = 'ERROR'  THEN N'FAIL'
         ELSE N'WARN' END AS verdict,
    res.sample_detail,
    res.load_batch_id,
    res.checked_at,
    r.description
FROM dq.quality_result AS res
JOIN dq.quality_rule   AS r ON r.rule_id = res.rule_id;
GO

/*  業務用檢視：把星狀綱要接起來，讓分析端不必自己寫 join。
    只取通過品質閘的當前版本，並保留 date_key 讓時序分析可行。 */
CREATE OR ALTER VIEW dw.v_statement_analysis AS
SELECT
    f.client_id,
    dt.date_key,
    dt.year_num,
    dt.month_num,
    c.risk_tier,
    c.age_band,
    e.education_desc,
    e.is_documented AS education_is_documented,
    m.marriage_desc,
    sx.sex_desc,
    ps.common_reading AS payment_status,
    ps.is_delinquent,
    f.bill_amount,
    f.payment_amount,
    f.credit_limit,
    CASE WHEN f.credit_limit > 0 THEN f.bill_amount / f.credit_limit END AS utilization,
    o.is_default
FROM dw.fact_monthly_statement AS f
JOIN dw.dim_customer       AS c  ON c.customer_sk    = f.customer_sk
JOIN dw.dim_date           AS dt ON dt.date_key      = f.date_key
JOIN dw.dim_education      AS e  ON e.education_key  = c.education_key
JOIN dw.dim_marriage       AS m  ON m.marriage_key   = c.marriage_key
JOIN dw.dim_sex            AS sx ON sx.sex_key       = c.sex_key
JOIN dw.dim_payment_status AS ps ON ps.pay_status_key = f.pay_status_key
LEFT JOIN dw.fact_default_outcome AS o ON o.client_id = f.client_id;
GO

PRINT '品質檢核程序與檢視建立完成';
GO
