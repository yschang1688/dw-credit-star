# 資料血緣

> 本檔由 `tools/lineage_md.py` 從 `dbt/target/manifest.json` 產出，**請勿手改**；
> CI 以 `--check` 比對，模型或 exposure 一改、文件沒重產就紅燈。
> 血緣的來源是 `ref()`／`source()` 依賴與 `exposures.yml` 宣告——推導出來的，不是畫出來的。

## 血緣圖

```mermaid
flowchart LR
  subgraph source["來源落地層（stg，由 T-SQL ETL 寫入）"]
    source_dw_credit_star_raw_credit_clients["credit_clients"]
  end
  subgraph seed["參考維度 seeds"]
    seed_dw_credit_star_dim_date["dim_date"]
    seed_dw_credit_star_dim_education["dim_education"]
    seed_dw_credit_star_dim_marriage["dim_marriage"]
    seed_dw_credit_star_dim_payment_status["dim_payment_status"]
    seed_dw_credit_star_dim_sex["dim_sex"]
  end
  subgraph staging["暫存層（view，不做業務轉換）"]
    model_dw_credit_star_stg_credit_clients["stg_credit_clients"]
    model_dw_credit_star_stg_monthly_snapshot["stg_monthly_snapshot"]
  end
  subgraph utilities["工具模型"]
    model_dw_credit_star_time_spine_day["time_spine_day"]
  end
  subgraph marts["維度／事實層"]
    model_dw_credit_star_dim_customer["dim_customer"]
    model_dw_credit_star_fact_default_outcome["fact_default_outcome"]
    model_dw_credit_star_fact_monthly_statement["fact_monthly_statement"]
  end
  subgraph semantic["語意層（指標唯一定義）"]
    metric_dw_credit_star_bill_amount_sum["📐 bill_amount_sum"]
    metric_dw_credit_star_credit_limit_sum["📐 credit_limit_sum"]
    metric_dw_credit_star_credit_utilization["📐 credit_utilization"]
    metric_dw_credit_star_customer_months["📐 customer_months"]
    metric_dw_credit_star_customers["📐 customers"]
    semantic_model_dw_credit_star_default_outcome["default_outcome"]
    metric_dw_credit_star_default_rate["📐 default_rate"]
    metric_dw_credit_star_defaults["📐 defaults"]
    metric_dw_credit_star_delinquency_rate["📐 delinquency_rate"]
    metric_dw_credit_star_delinquent_months["📐 delinquent_months"]
    semantic_model_dw_credit_star_monthly_statement["monthly_statement"]
  end
  subgraph exposure["下游消費者"]
    exposure_dw_credit_star_credit_risk_dashboard["📊 Tableau Public「credit-risk-dw-dashboard」"]
    exposure_dw_credit_star_data_dictionary["📊 資料字典（docs/data_dictionary.md）"]
  end
  metric_dw_credit_star_bill_amount_sum --> metric_dw_credit_star_credit_utilization
  metric_dw_credit_star_credit_limit_sum --> metric_dw_credit_star_credit_utilization
  metric_dw_credit_star_customer_months --> metric_dw_credit_star_delinquency_rate
  metric_dw_credit_star_customers --> metric_dw_credit_star_default_rate
  metric_dw_credit_star_defaults --> metric_dw_credit_star_default_rate
  metric_dw_credit_star_delinquent_months --> metric_dw_credit_star_delinquency_rate
  model_dw_credit_star_dim_customer --> exposure_dw_credit_star_credit_risk_dashboard
  model_dw_credit_star_dim_customer --> exposure_dw_credit_star_data_dictionary
  model_dw_credit_star_dim_customer --> model_dw_credit_star_fact_default_outcome
  model_dw_credit_star_dim_customer --> model_dw_credit_star_fact_monthly_statement
  model_dw_credit_star_fact_default_outcome --> exposure_dw_credit_star_credit_risk_dashboard
  model_dw_credit_star_fact_default_outcome --> exposure_dw_credit_star_data_dictionary
  model_dw_credit_star_fact_default_outcome --> semantic_model_dw_credit_star_default_outcome
  model_dw_credit_star_fact_monthly_statement --> exposure_dw_credit_star_credit_risk_dashboard
  model_dw_credit_star_fact_monthly_statement --> exposure_dw_credit_star_data_dictionary
  model_dw_credit_star_fact_monthly_statement --> semantic_model_dw_credit_star_monthly_statement
  model_dw_credit_star_stg_credit_clients --> model_dw_credit_star_stg_monthly_snapshot
  model_dw_credit_star_stg_monthly_snapshot --> model_dw_credit_star_dim_customer
  model_dw_credit_star_stg_monthly_snapshot --> model_dw_credit_star_fact_default_outcome
  model_dw_credit_star_stg_monthly_snapshot --> model_dw_credit_star_fact_monthly_statement
  seed_dw_credit_star_dim_date --> exposure_dw_credit_star_credit_risk_dashboard
  seed_dw_credit_star_dim_date --> model_dw_credit_star_fact_default_outcome
  seed_dw_credit_star_dim_date --> model_dw_credit_star_stg_monthly_snapshot
  seed_dw_credit_star_dim_date --> model_dw_credit_star_time_spine_day
  seed_dw_credit_star_dim_payment_status --> exposure_dw_credit_star_credit_risk_dashboard
  semantic_model_dw_credit_star_default_outcome --> metric_dw_credit_star_customers
  semantic_model_dw_credit_star_default_outcome --> metric_dw_credit_star_defaults
  semantic_model_dw_credit_star_monthly_statement --> metric_dw_credit_star_bill_amount_sum
  semantic_model_dw_credit_star_monthly_statement --> metric_dw_credit_star_credit_limit_sum
  semantic_model_dw_credit_star_monthly_statement --> metric_dw_credit_star_customer_months
  semantic_model_dw_credit_star_monthly_statement --> metric_dw_credit_star_delinquent_months
  source_dw_credit_star_raw_credit_clients --> model_dw_credit_star_stg_credit_clients
```

## 變更影響（改了左邊，右邊會受影響）

| 節點 | 層 | 直接下游 |
|---|---|---|
| `credit_clients` | source | stg_credit_clients |
| `dim_date` | seed | credit_risk_dashboard, fact_default_outcome, stg_monthly_snapshot, time_spine_day |
| `dim_education` | seed | — |
| `dim_marriage` | seed | — |
| `dim_payment_status` | seed | credit_risk_dashboard |
| `dim_sex` | seed | — |
| `stg_credit_clients` | staging | stg_monthly_snapshot |
| `stg_monthly_snapshot` | staging | dim_customer, fact_default_outcome, fact_monthly_statement |
| `time_spine_day` | utilities | — |
| `dim_customer` | marts | credit_risk_dashboard, data_dictionary, fact_default_outcome, fact_monthly_statement |
| `fact_default_outcome` | marts | credit_risk_dashboard, data_dictionary, default_outcome |
| `fact_monthly_statement` | marts | credit_risk_dashboard, data_dictionary, monthly_statement |
| `bill_amount_sum` | semantic | credit_utilization |
| `credit_limit_sum` | semantic | credit_utilization |
| `credit_utilization` | semantic | — |
| `customer_months` | semantic | delinquency_rate |
| `customers` | semantic | default_rate |
| `default_outcome` | semantic | customers, defaults |
| `default_rate` | semantic | — |
| `defaults` | semantic | default_rate |
| `delinquency_rate` | semantic | — |
| `delinquent_months` | semantic | delinquency_rate |
| `monthly_statement` | semantic | bill_amount_sum, credit_limit_sum, customer_months, delinquent_months |
| `credit_risk_dashboard` | exposure | — |
| `data_dictionary` | exposure | — |

## 業務指標的唯一定義（`dbt/models/marts/_semantic.yml`）

| 指標 | 分子 | 分母 |
|---|---|---|
| 額度使用率 (`credit_utilization`) | `bill_amount_sum` | `credit_limit_sum` |
| 違約率 (`default_rate`) | `defaults` | `customers` |
| 逾期率 (`delinquency_rate`) | `delinquent_months` | `customer_months` |

