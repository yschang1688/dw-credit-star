/*  分析查詢範例
    ---------------------------------------------------------------
    星狀綱要的價值不在「存得下」，在於**這些問題變得好問**。
    以下每一題若直接打在原始寬表上，都得寫一大段 UNPIVOT 或六段 UNION。
*/
USE CreditRiskDW;
GO

/* ── Q1 風險等級遷移矩陣 ─────────────────────────────────────
   「上個月是 LOW 的客戶，這個月跑去哪了？」
   這題只有 SCD Type 2 答得出來——若維度被就地覆寫，歷史等級早就不存在。 */
WITH tiers AS (
    SELECT f.client_id, f.date_key, c.risk_tier,
           LAG(c.risk_tier) OVER (PARTITION BY f.client_id ORDER BY f.date_key) AS prev_tier
      FROM dw.fact_monthly_statement AS f
      JOIN dw.dim_customer AS c ON c.customer_sk = f.customer_sk
)
SELECT prev_tier AS 前月等級, risk_tier AS 本月等級, COUNT(*) AS 客戶月數,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY prev_tier) AS DECIMAL(5,1)) AS 佔前月百分比
  FROM tiers
 WHERE prev_tier IS NOT NULL
 GROUP BY prev_tier, risk_tier
 ORDER BY CASE prev_tier WHEN 'LOW' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
          CASE risk_tier WHEN 'LOW' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;
GO

/* ── Q2 各風險等級的違約率 ───────────────────────────────────
   驗證風險分層真的有鑑別力：用「觀測期最後一個月」的等級對照次月違約。
   注意這裡刻意取 200509 的版本而非 is_current——雖然本例兩者相同，
   但寫成時點條件，日後補資料時才不會靜默失準。 */
SELECT c.risk_tier AS 風險等級,
       COUNT(*) AS 客戶數,
       SUM(CONVERT(INT, o.is_default)) AS 違約數,
       CAST(100.0 * SUM(CONVERT(INT, o.is_default)) / COUNT(*) AS DECIMAL(5,2)) AS 違約率百分比
  FROM dw.fact_default_outcome AS o
  JOIN dw.dim_customer AS c
    ON c.client_id = o.client_id
   AND 200509 BETWEEN c.valid_from_date AND c.valid_to_date
 GROUP BY c.risk_tier
 ORDER BY 違約率百分比 DESC;
GO

/* ── Q3 額度使用率分層 × 違約率 ──────────────────────────────
   比率型量值的正確算法：先各自加總分子與分母，再相除。
   直接對每列的 utilization 取平均會得到「平均的平均」，
   小額帳戶與大額帳戶被當成等權，結論會偏。 */
WITH util AS (
    SELECT f.client_id,
           SUM(f.bill_amount) AS total_bill,
           SUM(f.credit_limit) AS total_limit
      FROM dw.fact_monthly_statement AS f
     GROUP BY f.client_id
)
SELECT band AS 使用率區間, COUNT(*) AS 客戶數,
       CAST(100.0 * SUM(CONVERT(INT, o.is_default)) / COUNT(*) AS DECIMAL(5,2)) AS 違約率百分比
  FROM (SELECT u.client_id,
               CASE WHEN u.total_limit = 0 THEN N'無額度'
                    WHEN u.total_bill / u.total_limit < 0.1  THEN N'0-10%'
                    WHEN u.total_bill / u.total_limit < 0.3  THEN N'10-30%'
                    WHEN u.total_bill / u.total_limit < 0.6  THEN N'30-60%'
                    WHEN u.total_bill / u.total_limit < 0.9  THEN N'60-90%'
                    ELSE N'90%+' END AS band
          FROM util AS u) AS b
  JOIN dw.fact_default_outcome AS o ON o.client_id = b.client_id
 GROUP BY band
 ORDER BY MIN(CASE band WHEN N'0-10%' THEN 1 WHEN N'10-30%' THEN 2 WHEN N'30-60%' THEN 3
                        WHEN N'60-90%' THEN 4 WHEN N'90%+' THEN 5 ELSE 6 END);
GO

/* ── Q4 逾期月數趨勢 ─────────────────────────────────────────
   星狀綱要讓「跨月趨勢」變成單純的 GROUP BY，
   在原始寬表上要寫六段 UNION 才問得出來。 */
SELECT d.date_key AS 月份,
       COUNT(*) AS 帳戶數,
       SUM(CONVERT(INT, ps.is_delinquent)) AS 逾期帳戶數,
       CAST(100.0 * SUM(CONVERT(INT, ps.is_delinquent)) / COUNT(*) AS DECIMAL(5,2)) AS 逾期率百分比,
       CAST(AVG(CASE WHEN ps.is_delinquent = 1
                     THEN CONVERT(DECIMAL(5,2), ps.delinquent_months) END) AS DECIMAL(5,2)) AS 逾期者平均月數
  FROM dw.fact_monthly_statement AS f
  JOIN dw.dim_date AS d ON d.date_key = f.date_key
  JOIN dw.dim_payment_status AS ps ON ps.pay_status_key = f.pay_status_key
 GROUP BY d.date_key
 ORDER BY d.date_key;
GO
