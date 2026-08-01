/*  信用卡風險資料倉儲 — 星狀綱要 DDL
    ---------------------------------------------------------------
    來源：UCI「default of credit card clients」（台灣某銀行 2005，30,000 卡戶）
    來源結構是**橫斷面寬表**：一列一個客戶，六個月的帳單／繳款攤成 18 個欄位。
    倉儲要把它轉成「客戶 × 月份」的長格式事實表，這正是本專案的 ETL 主體。

    綱要分層（依 Kimball）：
      stg  暫存區：與來源同構，不做任何轉換，只負責落地與可重跑
      dw   維度與事實：星狀綱要本體
      dq   資料品質：稽核規則與結果，與資料同層而非事後報表
*/

IF DB_ID('CreditRiskDW') IS NULL
    CREATE DATABASE CreditRiskDW;
GO
USE CreditRiskDW;
GO

IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('dq')  IS NULL EXEC('CREATE SCHEMA dq');
GO

/*  重建前的拆除。
    順序必須是「反依賴」：先事實後維度，否則外鍵會擋住 DROP。
    第一版沒有這段，導致腳本跑到一半失敗後就無法重跑——
    DDL 腳本可重複執行（idempotent）不是加 IF EXISTS 就好，順序同樣是前提。 */
DROP TABLE IF EXISTS dw.fact_monthly_statement;
DROP TABLE IF EXISTS dw.fact_default_outcome;
DROP TABLE IF EXISTS dw.dim_customer;
DROP TABLE IF EXISTS dw.dim_date;
DROP TABLE IF EXISTS dw.dim_payment_status;
DROP TABLE IF EXISTS dw.dim_education;
DROP TABLE IF EXISTS dw.dim_marriage;
DROP TABLE IF EXISTS dw.dim_sex;
DROP TABLE IF EXISTS dq.quality_result;
DROP TABLE IF EXISTS dq.quality_rule;
DROP TABLE IF EXISTS dq.load_batch;
DROP TABLE IF EXISTS stg.credit_clients;
GO

/* ═══════════════════════════════════════════════════════════════
   暫存區：與來源同構
   ═══════════════════════════════════════════════════════════════ */
DROP TABLE IF EXISTS stg.credit_clients;
CREATE TABLE stg.credit_clients (
    client_id     INT           NOT NULL,
    limit_bal     DECIMAL(12,2) NULL,
    sex           TINYINT       NULL,
    education     TINYINT       NULL,
    marriage      TINYINT       NULL,
    age           SMALLINT      NULL,
    pay_1 SMALLINT NULL, pay_2 SMALLINT NULL, pay_3 SMALLINT NULL,
    pay_4 SMALLINT NULL, pay_5 SMALLINT NULL, pay_6 SMALLINT NULL,
    bill_amt1 DECIMAL(14,2) NULL, bill_amt2 DECIMAL(14,2) NULL, bill_amt3 DECIMAL(14,2) NULL,
    bill_amt4 DECIMAL(14,2) NULL, bill_amt5 DECIMAL(14,2) NULL, bill_amt6 DECIMAL(14,2) NULL,
    pay_amt1  DECIMAL(14,2) NULL, pay_amt2  DECIMAL(14,2) NULL, pay_amt3  DECIMAL(14,2) NULL,
    pay_amt4  DECIMAL(14,2) NULL, pay_amt5  DECIMAL(14,2) NULL, pay_amt6  DECIMAL(14,2) NULL,
    default_next_month BIT     NULL,
    load_batch_id UNIQUEIDENTIFIER NOT NULL,
    loaded_at     DATETIME2(0)     NOT NULL CONSTRAINT DF_stg_loaded DEFAULT SYSUTCDATETIME()
);
CREATE CLUSTERED INDEX IX_stg_credit_clients_batch ON stg.credit_clients (load_batch_id, client_id);
GO

/* ═══════════════════════════════════════════════════════════════
   維度表
   ═══════════════════════════════════════════════════════════════ */

/*  日期維度。
    來源資料的六個月無明確年月，僅以 PAY_1..PAY_6 表示「最近月」到「最早月」。
    依 UCI 文件所述觀測期間為 2005/04–2005/09，據此展開；此對應寫入資料字典。 */
DROP TABLE IF EXISTS dw.dim_date;
CREATE TABLE dw.dim_date (
    date_key        INT          NOT NULL CONSTRAINT PK_dim_date PRIMARY KEY,  -- yyyymm
    year_num        SMALLINT     NOT NULL,
    month_num       TINYINT      NOT NULL,
    month_name_zh   NVARCHAR(10) NOT NULL,
    quarter_num     TINYINT      NOT NULL,
    month_end_date  DATE         NOT NULL,
    -- 來源欄位序號（1=最近月…6=最早月），ETL 用它把寬表攤平
    source_month_ix TINYINT      NOT NULL,
    CONSTRAINT UQ_dim_date_source_ix UNIQUE (source_month_ix)
);
GO

/*  性別／教育／婚姻：小型參考維度。
    刻意保留來源碼值，並標記「是否在資料字典中有定義」——
    這份資料的 EDUCATION 實際出現 0/5/6、MARRIAGE 出現 0，但官方文件都沒定義。
    倉儲不該把未定義值悄悄併成「其他」，那會讓下游永遠看不到資料字典的缺口。 */
DROP TABLE IF EXISTS dw.dim_education;
CREATE TABLE dw.dim_education (
    education_key   TINYINT      NOT NULL CONSTRAINT PK_dim_education PRIMARY KEY,
    education_code  TINYINT      NOT NULL,
    education_desc  NVARCHAR(30) NOT NULL,
    is_documented   BIT          NOT NULL,   -- 官方資料字典有無定義
    CONSTRAINT UQ_dim_education_code UNIQUE (education_code)
);

DROP TABLE IF EXISTS dw.dim_marriage;
CREATE TABLE dw.dim_marriage (
    marriage_key    TINYINT      NOT NULL CONSTRAINT PK_dim_marriage PRIMARY KEY,
    marriage_code   TINYINT      NOT NULL,
    marriage_desc   NVARCHAR(30) NOT NULL,
    is_documented   BIT          NOT NULL,
    CONSTRAINT UQ_dim_marriage_code UNIQUE (marriage_code)
);

DROP TABLE IF EXISTS dw.dim_sex;
CREATE TABLE dw.dim_sex (
    sex_key   TINYINT      NOT NULL CONSTRAINT PK_dim_sex PRIMARY KEY,
    sex_code  TINYINT      NOT NULL,
    sex_desc  NVARCHAR(10) NOT NULL,
    CONSTRAINT UQ_dim_sex_code UNIQUE (sex_code)
);

/*  繳款狀態維度：把 PAY_* 的碼值語意集中一處。
    這欄是本資料集最惡名昭彰的地方——官方文件只定義 -1=按時繳款、1..9=延遲月數，
    但實際資料大量出現 -2 與 0。學界慣例將 -2 讀為「無消費」、0 讀為「循環信用」，
    但那是推論不是文件。維度表把「文件定義」與「通行解讀」分欄存放，不混為一談。 */
DROP TABLE IF EXISTS dw.dim_payment_status;
CREATE TABLE dw.dim_payment_status (
    pay_status_key    TINYINT      NOT NULL CONSTRAINT PK_dim_pay_status PRIMARY KEY,
    pay_status_code   SMALLINT     NOT NULL,
    documented_desc   NVARCHAR(40) NULL,      -- 官方文件的定義；未定義則 NULL
    common_reading    NVARCHAR(40) NOT NULL,  -- 學界通行解讀（推論）
    is_delinquent     BIT          NOT NULL,  -- 是否為逾期狀態
    delinquent_months TINYINT      NULL,
    CONSTRAINT UQ_dim_pay_status_code UNIQUE (pay_status_code)
);
GO

/*  客戶維度（SCD Type 2）。
    ---------------------------------------------------------------
    誠實說明：來源是單一時點快照，信用額度在原始資料中不隨月份變動，
    因此**不能**假造額度變更歷史。本維度的緩慢變化由「風險等級」驅動——
    每月依當期繳款狀態與額度使用率重算等級，等級變動即封版並開新版本。

    業務理由：放款覆核要能回答「當初核准時這位客戶是什麼等級」，
    若維度被就地覆寫（SCD Type 1），這個問題就永遠答不出來。 */
DROP TABLE IF EXISTS dw.dim_customer;
CREATE TABLE dw.dim_customer (
    customer_sk     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_customer PRIMARY KEY,
    client_id       INT          NOT NULL,          -- 業務主鍵（自然鍵）
    limit_bal       DECIMAL(12,2) NOT NULL,
    sex_key         TINYINT      NOT NULL CONSTRAINT FK_cust_sex       REFERENCES dw.dim_sex(sex_key),
    education_key   TINYINT      NOT NULL CONSTRAINT FK_cust_education REFERENCES dw.dim_education(education_key),
    marriage_key    TINYINT      NOT NULL CONSTRAINT FK_cust_marriage  REFERENCES dw.dim_marriage(marriage_key),
    age             SMALLINT     NOT NULL,
    age_band        NVARCHAR(10) NOT NULL,
    risk_tier       NVARCHAR(10) NOT NULL,          -- SCD2 追蹤對象
    -- SCD Type 2 欄位
    valid_from_date INT          NOT NULL,          -- date_key
    valid_to_date   INT          NOT NULL,          -- 9999 12 表示當前版本
    is_current      BIT          NOT NULL,
    version_num     SMALLINT     NOT NULL,
    row_hash        BINARY(32)   NOT NULL,          -- 追蹤欄位的雜湊，用於偵測變更
    created_at      DATETIME2(0) NOT NULL CONSTRAINT DF_dim_cust_created DEFAULT SYSUTCDATETIME()
);
-- 自然鍵 + 有效期間必須唯一：同一客戶同一時點不得有兩個版本
CREATE UNIQUE INDEX UX_dim_customer_nk_from ON dw.dim_customer (client_id, valid_from_date);
-- 當前版本查詢是最高頻的存取路徑
CREATE UNIQUE INDEX UX_dim_customer_current ON dw.dim_customer (client_id)
    WHERE is_current = 1;
GO

/* ═══════════════════════════════════════════════════════════════
   事實表
   ═══════════════════════════════════════════════════════════════ */

/*  月度帳單事實。粒度：一個客戶 × 一個月 = 一列（宣告粒度是星狀綱要的第一件事）。
    30,000 客戶 × 6 月 = 180,000 列。 */
DROP TABLE IF EXISTS dw.fact_monthly_statement;
CREATE TABLE dw.fact_monthly_statement (
    statement_sk    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_fact_stmt PRIMARY KEY,
    customer_sk     BIGINT        NOT NULL CONSTRAINT FK_stmt_customer REFERENCES dw.dim_customer(customer_sk),
    date_key        INT           NOT NULL CONSTRAINT FK_stmt_date     REFERENCES dw.dim_date(date_key),
    pay_status_key  TINYINT       NOT NULL CONSTRAINT FK_stmt_paystat  REFERENCES dw.dim_payment_status(pay_status_key),
    client_id       INT           NOT NULL,       -- 退化維度：便於稽核回溯來源
    -- 可加總量值
    bill_amount     DECIMAL(14,2) NOT NULL,
    payment_amount  DECIMAL(14,2) NOT NULL,
    -- 非可加總（比率）：存分子分母，讓下游自己彙總後再算，避免「平均的平均」
    credit_limit    DECIMAL(12,2) NOT NULL,
    load_batch_id   UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT UQ_fact_stmt_grain UNIQUE (client_id, date_key)   -- 粒度守衛
);
CREATE INDEX IX_fact_stmt_date ON dw.fact_monthly_statement (date_key) INCLUDE (bill_amount, payment_amount);
CREATE INDEX IX_fact_stmt_cust ON dw.fact_monthly_statement (customer_sk);
GO

/*  違約結果事實。粒度：一個客戶一列（觀測期結束後次月是否違約）。
    與帳單事實分開，因為粒度不同——混在同一張表會讓違約旗標被重複計算六次。 */
DROP TABLE IF EXISTS dw.fact_default_outcome;
CREATE TABLE dw.fact_default_outcome (
    outcome_sk      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_fact_outcome PRIMARY KEY,
    customer_sk     BIGINT NOT NULL CONSTRAINT FK_outcome_customer REFERENCES dw.dim_customer(customer_sk),
    date_key        INT    NOT NULL CONSTRAINT FK_outcome_date     REFERENCES dw.dim_date(date_key),
    client_id       INT    NOT NULL,
    is_default      BIT    NOT NULL,
    load_batch_id   UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT UQ_fact_outcome_grain UNIQUE (client_id)
);
GO

/* ═══════════════════════════════════════════════════════════════
   資料品質層
   ═══════════════════════════════════════════════════════════════ */

/*  稽核規則登錄表。規則是資料而不是程式碼——新增規則不必改 ETL。
    命名註記：不用 dq.rule，RULE 是 T-SQL 保留字（舊版 CREATE RULE 語法），
    綱要設計避開保留字比事後加中括號可靠。 */
DROP TABLE IF EXISTS dq.quality_rule;
CREATE TABLE dq.quality_rule (
    rule_id       INT           NOT NULL CONSTRAINT PK_dq_quality_rule PRIMARY KEY,
    rule_code     VARCHAR(40)   NOT NULL,
    target_object NVARCHAR(80)  NOT NULL,
    severity      VARCHAR(10)   NOT NULL CONSTRAINT CK_dq_severity
                      CHECK (severity IN ('ERROR','WARN','INFO')),
    description   NVARCHAR(300) NOT NULL,
    CONSTRAINT UQ_dq_quality_rule_code UNIQUE (rule_code)
);

DROP TABLE IF EXISTS dq.quality_result;
CREATE TABLE dq.quality_result (
    result_id      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dq_quality_result PRIMARY KEY,
    rule_id        INT              NOT NULL CONSTRAINT FK_dq_quality_result_rule REFERENCES dq.quality_rule(rule_id),
    load_batch_id  UNIQUEIDENTIFIER NOT NULL,
    checked_at     DATETIME2(0)     NOT NULL CONSTRAINT DF_dq_checked DEFAULT SYSUTCDATETIME(),
    rows_checked   BIGINT           NOT NULL,
    rows_failed    BIGINT           NOT NULL,
    sample_detail  NVARCHAR(400)    NULL          -- 失敗樣本，供追查
);
CREATE INDEX IX_dq_quality_result_batch ON dq.quality_result (load_batch_id, rule_id);
GO

/*  批次執行紀錄：每次 ETL 一列，讓「這份數字是哪一批載進來的」可回答。 */
DROP TABLE IF EXISTS dq.load_batch;
CREATE TABLE dq.load_batch (
    load_batch_id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_load_batch PRIMARY KEY,
    started_at    DATETIME2(0)     NOT NULL,
    finished_at   DATETIME2(0)     NULL,
    source_name   NVARCHAR(100)    NOT NULL,
    source_rows   INT              NULL,
    status        VARCHAR(12)      NOT NULL CONSTRAINT CK_batch_status
                      CHECK (status IN ('RUNNING','SUCCEEDED','FAILED')),
    message       NVARCHAR(400)    NULL
);
GO

PRINT '綱要建立完成：stg / dw / dq';
GO
