# BigQuery（Sandbox）實跑存證

> 產生於 2026-08-10。專案為短命環境，存證後即拆除。
> Sandbox＝**無計費帳戶**，這是本次三朵雲裡唯一的『硬性』成本上限。

## 計費狀態（跑之前與之後都查過）

```json
{
  "projectId": "dw-credit-star",
  "billingAccountName": "",
  "billingEnabled": false
}
```

## 產出物

| dataset | 表 | 列數 |
|---|---|---:|
| credit_dw_raw | credit_clients | 30,000 |
| credit_dw_stg | stg_credit_clients | （view） |
| credit_dw_stg | stg_monthly_snapshot | （view） |
| credit_dw_dw | dim_customer | 51,110 |
| credit_dw_dw | dim_date | 7 |
| credit_dw_dw | dim_education | 7 |
| credit_dw_dw | dim_marriage | 4 |
| credit_dw_dw | dim_payment_status | 12 |
| credit_dw_dw | dim_sex | 2 |
| credit_dw_dw | fact_default_outcome | 30,000 |
| credit_dw_dw | fact_monthly_statement | 180,000 |

## 與 SQL Server 版對帳

| section | k1 | k2 | k3 |
|---|---|---|---|
| count | dim_customer_naturals | 30000 |  |
| count | dim_customer_versions | 51110 |  |
| count | fact_default_outcome | 30000 |  |
| count | fact_monthly_statement | 180000 |  |
| tier_by_month | 200504 | HIGH | 3079 |
| tier_by_month | 200504 | LOW | 24864 |
| tier_by_month | 200504 | MEDIUM | 2057 |
| tier_by_month | 200505 | HIGH | 2968 |
| tier_by_month | 200505 | LOW | 24750 |
| tier_by_month | 200505 | MEDIUM | 2282 |
| tier_by_month | 200506 | HIGH | 3508 |
| tier_by_month | 200506 | LOW | 23507 |
| tier_by_month | 200506 | MEDIUM | 2985 |
| tier_by_month | 200507 | HIGH | 4209 |
| tier_by_month | 200507 | LOW | 21866 |
| tier_by_month | 200507 | MEDIUM | 3925 |
| tier_by_month | 200508 | HIGH | 4410 |
| tier_by_month | 200508 | LOW | 21193 |
| tier_by_month | 200508 | MEDIUM | 4397 |
| tier_by_month | 200509 | HIGH | 3130 |
| tier_by_month | 200509 | LOW | 18719 |
| tier_by_month | 200509 | MEDIUM | 8151 |
| tier_default_rate | HIGH | 3130 | 69.6 |
| tier_default_rate | LOW | 18719 | 13.2 |
| tier_default_rate | MEDIUM | 8151 | 24.3 |

**逐列比對結果：25 列全部一致**（列數、每月各 risk_tier 客戶數、風險分層違約率）。
比對腳本同時查 BigQuery 與本機 SQL Server 容器，任何一格不同即列出差異。

不比的兩項：代理鍵的值（`IDENTITY` vs `FARM_FINGERPRINT`）與 `valid_to_date`
的端點慣例（封版寫「前一個月」vs「下一版起始月」）——那兩項本來就不同，
比它們只會比出「實作不同」，不是要驗的東西。

## Sandbox 的 DML 限制：實測而非引用文件

```
DDL (CREATE OR REPLACE TABLE AS SELECT) : 可用
DML (UPDATE)                            : 403 Billing has not been enabled ...
                                          DML queries are not allowed in the free tier.
DML (MERGE)                             : 同上
```

本專案的模型全是 `view` 與 `table`（產生 DDL）故可跑完；`dbt seed` 的日誌雖然
印 `INSERT n`，實際走的是載入作業而非 DML，所以也沒被擋。
**任何模型一旦改成 `incremental`，dbt 會產生 `MERGE` 而直接 403**——
到那時就得啟用計費，硬上限也就消失了。

## 拆除與實查歸零

```
  刪除 dw-credit-star.credit_dw_raw
  刪除 dw-credit-star.credit_dw_dw
  刪除 dw-credit-star.credit_dw_stg
實查剩餘 dataset：（空）
```

拆除後再查一次計費：`billingEnabled: false`（全程未曾啟用）。

> **實查當場抓到殘留。** 拆除腳本第一版用寫死的名單
> `("credit_dw_raw", "credit_dw", "credit_dw_stg")`，三個都刪除成功、腳本一聲不吭，
> 但實查列出 `['credit_dw_dw']`——dbt 的 dataset 名是「profile 的 `dataset` ＋ 模型的
> `+schema`」串出來的（`credit_dw` + `dw`），寫死的人（我）用直覺猜了名字。
> 這正是「**指令沒報錯 ≠ 帳戶裡沒東西**」的實例，也說明為什麼拆除的最後一步
> 必須是列舉實查而不是相信刪除指令的回傳。已改為列舉後刪除。
