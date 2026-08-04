# 資料字典 — CreditRiskDW

> **本檔由 `etl/gen_data_dictionary.py` 從資料庫系統目錄自動產出，請勿手改。**
> 手寫的資料字典必定過期——欄位改了沒人記得改文件，久了就沒人信。
> 從 `sys.tables` / `sys.columns` 讀取，文件與實際綱要不可能不一致。

產出時間：2026-08-04 01:01 UTC

## `stg` — 暫存區：與來源同構，不做轉換，只負責落地與可重跑

共 1 張表。

### `stg.credit_clients`　（30,000 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `client_id` | int | 否 |  |  |
| `limit_bal` | decimal(12,2) | 是 |  |  |
| `sex` | tinyint | 是 |  |  |
| `education` | tinyint | 是 |  |  |
| `marriage` | tinyint | 是 |  |  |
| `age` | smallint | 是 |  |  |
| `pay_1` | smallint | 是 |  |  |
| `pay_2` | smallint | 是 |  |  |
| `pay_3` | smallint | 是 |  |  |
| `pay_4` | smallint | 是 |  |  |
| `pay_5` | smallint | 是 |  |  |
| `pay_6` | smallint | 是 |  |  |
| `bill_amt1` | decimal(14,2) | 是 |  |  |
| `bill_amt2` | decimal(14,2) | 是 |  |  |
| `bill_amt3` | decimal(14,2) | 是 |  |  |
| `bill_amt4` | decimal(14,2) | 是 |  |  |
| `bill_amt5` | decimal(14,2) | 是 |  |  |
| `bill_amt6` | decimal(14,2) | 是 |  |  |
| `pay_amt1` | decimal(14,2) | 是 |  |  |
| `pay_amt2` | decimal(14,2) | 是 |  |  |
| `pay_amt3` | decimal(14,2) | 是 |  |  |
| `pay_amt4` | decimal(14,2) | 是 |  |  |
| `pay_amt5` | decimal(14,2) | 是 |  |  |
| `pay_amt6` | decimal(14,2) | 是 |  |  |
| `default_next_month` | bit | 是 |  |  |
| `load_batch_id` | uniqueidentifier | 否 |  |  |
| `loaded_at` | datetime2 | 否 |  |  |

## `dw` — 維度與事實：星狀綱要本體

共 8 張表。

### `dw.dim_customer`　（51,110 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `customer_sk` | bigint (identity) | 否 | PK |  |
| `client_id` | int | 否 |  |  |
| `limit_bal` | decimal(12,2) | 否 |  |  |
| `sex_key` | tinyint | 否 | FK | `dw.dim_sex.sex_key` |
| `education_key` | tinyint | 否 | FK | `dw.dim_education.education_key` |
| `marriage_key` | tinyint | 否 | FK | `dw.dim_marriage.marriage_key` |
| `age` | smallint | 否 |  |  |
| `age_band` | nvarchar(10) | 否 |  |  |
| `risk_tier` | nvarchar(10) | 否 |  |  |
| `valid_from_date` | int | 否 |  |  |
| `valid_to_date` | int | 否 |  |  |
| `is_current` | bit | 否 |  |  |
| `version_num` | smallint | 否 |  |  |
| `row_hash` | binary(32) | 否 |  |  |
| `created_at` | datetime2 | 否 |  |  |

### `dw.dim_date`　（7 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `date_key` | int | 否 | PK |  |
| `year_num` | smallint | 否 |  |  |
| `month_num` | tinyint | 否 |  |  |
| `month_name_zh` | nvarchar(10) | 否 |  |  |
| `quarter_num` | tinyint | 否 |  |  |
| `month_end_date` | date | 否 |  |  |
| `source_month_ix` | tinyint | 否 |  |  |

### `dw.dim_education`　（7 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `education_key` | tinyint | 否 | PK |  |
| `education_code` | tinyint | 否 |  |  |
| `education_desc` | nvarchar(30) | 否 |  |  |
| `is_documented` | bit | 否 |  |  |

### `dw.dim_marriage`　（4 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `marriage_key` | tinyint | 否 | PK |  |
| `marriage_code` | tinyint | 否 |  |  |
| `marriage_desc` | nvarchar(30) | 否 |  |  |
| `is_documented` | bit | 否 |  |  |

### `dw.dim_payment_status`　（12 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `pay_status_key` | tinyint | 否 | PK |  |
| `pay_status_code` | smallint | 否 |  |  |
| `documented_desc` | nvarchar(40) | 是 |  |  |
| `common_reading` | nvarchar(40) | 否 |  |  |
| `is_delinquent` | bit | 否 |  |  |
| `delinquent_months` | tinyint | 是 |  |  |

### `dw.dim_sex`　（2 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `sex_key` | tinyint | 否 | PK |  |
| `sex_code` | tinyint | 否 |  |  |
| `sex_desc` | nvarchar(10) | 否 |  |  |

### `dw.fact_default_outcome`　（30,000 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `outcome_sk` | bigint (identity) | 否 | PK |  |
| `customer_sk` | bigint | 否 | FK | `dw.dim_customer.customer_sk` |
| `date_key` | int | 否 | FK | `dw.dim_date.date_key` |
| `client_id` | int | 否 |  |  |
| `is_default` | bit | 否 |  |  |
| `load_batch_id` | uniqueidentifier | 否 |  |  |

### `dw.fact_monthly_statement`　（180,000 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `statement_sk` | bigint (identity) | 否 | PK |  |
| `customer_sk` | bigint | 否 | FK | `dw.dim_customer.customer_sk` |
| `date_key` | int | 否 | FK | `dw.dim_date.date_key` |
| `pay_status_key` | tinyint | 否 | FK | `dw.dim_payment_status.pay_status_key` |
| `client_id` | int | 否 |  |  |
| `bill_amount` | decimal(14,2) | 否 |  |  |
| `payment_amount` | decimal(14,2) | 否 |  |  |
| `credit_limit` | decimal(12,2) | 否 |  |  |
| `load_batch_id` | uniqueidentifier | 否 |  |  |

## `dq` — 資料品質：稽核規則、結果與批次紀錄

共 3 張表。

### `dq.load_batch`　（1 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `load_batch_id` | uniqueidentifier | 否 | PK |  |
| `started_at` | datetime2 | 否 |  |  |
| `finished_at` | datetime2 | 是 |  |  |
| `source_name` | nvarchar(100) | 否 |  |  |
| `source_rows` | int | 是 |  |  |
| `status` | varchar(12) | 否 |  |  |
| `message` | nvarchar(400) | 是 |  |  |

### `dq.quality_result`　（12 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `result_id` | bigint (identity) | 否 | PK |  |
| `rule_id` | int | 否 | FK | `dq.quality_rule.rule_id` |
| `load_batch_id` | uniqueidentifier | 否 |  |  |
| `checked_at` | datetime2 | 否 |  |  |
| `rows_checked` | bigint | 否 |  |  |
| `rows_failed` | bigint | 否 |  |  |
| `sample_detail` | nvarchar(400) | 是 |  |  |

### `dq.quality_rule`　（12 列）

| 欄位 | 型別 | 可空 | 鍵 | 參照 |
|---|---|---|---|---|
| `rule_id` | int | 否 | PK |  |
| `rule_code` | varchar(40) | 否 |  |  |
| `target_object` | nvarchar(80) | 否 |  |  |
| `severity` | varchar(10) | 否 |  |  |
| `description` | nvarchar(300) | 否 |  |  |

## 碼值對照

### 繳款狀態 `dw.dim_payment_status`

| 碼值 | 官方文件定義 | 通行解讀 |
|---|---|---|
| `-2` | （文件未定義） | 當期無消費（推論） |
| `-1` | 按時繳款 | 按時繳清 |
| `0` | （文件未定義） | 使用循環信用（推論） |
| `1` | 延遲 1 個月 | 延遲 1 個月 |
| `2` | 延遲 2 個月 | 延遲 2 個月 |
| `3` | 延遲 3 個月 | 延遲 3 個月 |
| `4` | 延遲 4 個月 | 延遲 4 個月 |
| `5` | 延遲 5 個月 | 延遲 5 個月 |
| `6` | 延遲 6 個月 | 延遲 6 個月 |
| `7` | 延遲 7 個月 | 延遲 7 個月 |
| `8` | 延遲 8 個月 | 延遲 8 個月 |
| `9` | 延遲 9 個月以上 | 延遲 9 個月以上 |

### 教育程度 `dw.dim_education`

| 碼值 | 說明 | 文件有定義 |
|---|---|---|
| `1` | 研究所 | 是 |
| `2` | 大學 | 是 |
| `3` | 高中 | 是 |
| `4` | 其他 | 是 |
| `0` | 未定義碼值 0 | 否 |
| `5` | 未定義碼值 5 | 否 |
| `6` | 未定義碼值 6 | 否 |

### 婚姻狀況 `dw.dim_marriage`

| 碼值 | 說明 | 文件有定義 |
|---|---|---|
| `1` | 已婚 | 是 |
| `2` | 單身 | 是 |
| `3` | 其他 | 是 |
| `0` | 未定義碼值 0 | 否 |

## 已知的來源資料缺口

以下不是倉儲的錯誤，是**來源資料與其官方文件不符**，如實記錄以免下游誤用：

- `EDUCATION` 官方文件只定義 1–4，實際資料出現 0、5、6
- `MARRIAGE` 官方文件只定義 1–3，實際資料出現 0
- `PAY_*` 官方文件只定義 −1 與 1–9，實際資料大量出現 −2 與 0；學界通行解讀為「當期無消費」與「使用循環信用」，但**那是推論不是文件**，故維度表把兩者分欄存放
