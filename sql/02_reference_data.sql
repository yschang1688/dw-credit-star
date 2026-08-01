/*  參考維度種子資料
    ---------------------------------------------------------------
    設計立場：**碼值語意集中在維度表，不散在 ETL 程式或報表裡。**
    來源資料有大量「文件沒定義但實際存在」的碼值，這裡把它們如實登錄並標記，
    而不是靜靜併進「其他」——那會讓資料字典的缺口永遠不被看見。
*/
USE CreditRiskDW;
GO

/* ── 日期維度 ────────────────────────────────────────────────
   來源只用 PAY_1..PAY_6 表示「最近月」到「最早月」，沒有實際年月。
   依 UCI 文件所述觀測期間 2005/04–2005/09 對應：
     source_month_ix=1 → 2005/09（最近）… 6 → 2005/04（最早） */
INSERT INTO dw.dim_date (date_key, year_num, month_num, month_name_zh, quarter_num, month_end_date, source_month_ix)
VALUES
    (200509, 2005, 9, N'2005年9月', 3, '2005-09-30', 1),
    (200508, 2005, 8, N'2005年8月', 3, '2005-08-31', 2),
    (200507, 2005, 7, N'2005年7月', 3, '2005-07-31', 3),
    (200506, 2005, 6, N'2005年6月', 2, '2005-06-30', 4),
    (200505, 2005, 5, N'2005年5月', 2, '2005-05-31', 5),
    (200504, 2005, 4, N'2005年4月', 2, '2005-04-30', 6),
    -- 違約觀測月：事實表 fact_default_outcome 掛在此月
    (200510, 2005,10, N'2005年10月',4, '2005-10-31', 7);
GO

/* ── 性別 ─────────────────────────────────────────────────── */
INSERT INTO dw.dim_sex (sex_key, sex_code, sex_desc) VALUES
    (1, 1, N'男'), (2, 2, N'女');
GO

/* ── 教育程度 ─────────────────────────────────────────────────
   官方文件只定義 1=研究所 2=大學 3=高中 4=其他。
   實際資料另有 0、5、6 三個值共約 0.1%，來源不明——標記 is_documented=0，
   讓下游查詢能一眼看出「這幾類的語意沒有依據」。 */
INSERT INTO dw.dim_education (education_key, education_code, education_desc, is_documented) VALUES
    (1, 1, N'研究所',        1),
    (2, 2, N'大學',          1),
    (3, 3, N'高中',          1),
    (4, 4, N'其他',          1),
    (5, 0, N'未定義碼值 0',  0),
    (6, 5, N'未定義碼值 5',  0),
    (7, 6, N'未定義碼值 6',  0);
GO

/* ── 婚姻狀況 ─────────────────────────────────────────────────
   官方文件只定義 1=已婚 2=單身 3=其他；實際另有 0。 */
INSERT INTO dw.dim_marriage (marriage_key, marriage_code, marriage_desc, is_documented) VALUES
    (1, 1, N'已婚',         1),
    (2, 2, N'單身',         1),
    (3, 3, N'其他',         1),
    (4, 0, N'未定義碼值 0', 0);
GO

/* ── 繳款狀態 ─────────────────────────────────────────────────
   本資料集最有名的爭議欄位。官方文件寫：
     -1 = 按時繳款，1..9 = 延遲月數
   但實際資料裡 -2 與 0 合計超過半數。學界通行解讀是
     -2 = 當期無消費、0 = 使用循環信用（繳了最低應繳但未清償）
   ——那是推論，不是文件。
   維度表把「文件定義」與「通行解讀」**分欄存放**：
   下游若要嚴格依文件，就只採用 documented_desc 非空的列。 */
INSERT INTO dw.dim_payment_status
    (pay_status_key, pay_status_code, documented_desc, common_reading, is_delinquent, delinquent_months) VALUES
    ( 1, -2, NULL,            N'當期無消費（推論）',     0, NULL),
    ( 2, -1, N'按時繳款',      N'按時繳清',              0, NULL),
    ( 3,  0, NULL,            N'使用循環信用（推論）',   0, NULL),
    ( 4,  1, N'延遲 1 個月',   N'延遲 1 個月',           1, 1),
    ( 5,  2, N'延遲 2 個月',   N'延遲 2 個月',           1, 2),
    ( 6,  3, N'延遲 3 個月',   N'延遲 3 個月',           1, 3),
    ( 7,  4, N'延遲 4 個月',   N'延遲 4 個月',           1, 4),
    ( 8,  5, N'延遲 5 個月',   N'延遲 5 個月',           1, 5),
    ( 9,  6, N'延遲 6 個月',   N'延遲 6 個月',           1, 6),
    (10,  7, N'延遲 7 個月',   N'延遲 7 個月',           1, 7),
    (11,  8, N'延遲 8 個月',   N'延遲 8 個月',           1, 8),
    (12,  9, N'延遲 9 個月以上', N'延遲 9 個月以上',      1, 9);
GO

/* ── 資料品質規則登錄 ──────────────────────────────────────── */
INSERT INTO dq.quality_rule (rule_id, rule_code, target_object, severity, description) VALUES
    (1, 'STG_ROWCOUNT',        N'stg.credit_clients',          'ERROR',
        N'暫存區載入筆數需等於來源筆數，落差代表擷取階段掉資料'),
    (2, 'STG_PK_UNIQUE',       N'stg.credit_clients',          'ERROR',
        N'client_id 在單一批次內必須唯一'),
    (3, 'DIM_EDU_UNDOCUMENTED',N'dw.dim_customer',             'WARN',
        N'教育程度落在官方文件未定義的碼值（0/5/6）'),
    (4, 'DIM_MAR_UNDOCUMENTED',N'dw.dim_customer',             'WARN',
        N'婚姻狀況落在官方文件未定義的碼值（0）'),
    (5, 'FACT_GRAIN',          N'dw.fact_monthly_statement',   'ERROR',
        N'事實表粒度必須為「客戶×月份」唯一，重複即為 ETL 重跑造成的重複載入'),
    (6, 'FACT_ORPHAN_FK',      N'dw.fact_monthly_statement',   'ERROR',
        N'事實列的 customer_sk 必須存在於維度表（孤兒鍵）'),
    (7, 'FACT_ROWCOUNT',       N'dw.fact_monthly_statement',   'ERROR',
        N'事實筆數需等於 客戶數 × 月份數，落差代表攤平階段掉列'),
    (8, 'SCD2_NO_OVERLAP',     N'dw.dim_customer',             'ERROR',
        N'同一客戶的版本有效期間不得重疊，重疊會讓事實表關聯到兩個版本'),
    (9, 'SCD2_ONE_CURRENT',    N'dw.dim_customer',             'ERROR',
        N'同一客戶恰有一筆 is_current=1'),
    (10,'FACT_NEG_PAYMENT',    N'dw.fact_monthly_statement',   'WARN',
        N'繳款金額為負；來源確實存在，多為退款或調整，保留但標記'),
    (11,'FACT_BILL_OVER_LIMIT',N'dw.fact_monthly_statement',   'WARN',
        N'帳單金額超過信用額度；可能為超額動用或額度調降，需業務確認'),
    (12,'OUTCOME_COVERAGE',    N'dw.fact_default_outcome',     'ERROR',
        N'每位客戶都應有一筆違約結果');
GO

PRINT '參考維度與品質規則種子完成';
GO
