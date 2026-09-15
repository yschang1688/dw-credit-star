{#
  跨引擎方言差異的唯一集中點。

  模型檔裡不准出現任何引擎專屬函數——差異全部走 adapter.dispatch 收在這裡，
  模型讀起來才是「一份語意」，而不是三份實作的縫合。

  dispatch 的解析順序是「當前 adapter 的實作 → default__」。
  default__ 一律寫 T-SQL 方言，這是刻意的：dbt-sqlserver（本機 Azure SQL Edge）、
  dbt-fabric（Microsoft Fabric Warehouse）、dbt-synapse 講的都是 T-SQL，
  三個 adapter 都會落到同一份 default__——換句話說，今天在本機容器上驗過的模型，
  接上 Fabric 只需要在 profiles.yml 換一個 target，模型與測試一行都不用動。
#}


{#— 確定性代理鍵：把各部位串成 'a|b' 再雜湊成 BIGINT。—#}
{#— 兩邊的串接結果逐字元相同（整數轉字串無格式差異），   —#}
{#— 但雜湊函數不同，所以「鍵值」只在同引擎內可比、跨引擎不可比； —#}
{#— 跨引擎對帳一律比自然鍵與區間（見 analyses/），不比代理鍵。   —#}

{% macro hash_sk(parts) %}{{ adapter.dispatch('hash_sk', 'dw_credit_star')(parts) }}{% endmacro %}

{% macro bigquery__hash_sk(parts) -%}
farm_fingerprint(concat({% for p in parts %}cast({{ p }} as string){% if not loop.last %}, '|', {% endif %}{% endfor %}))
{%- endmacro %}

{% macro default__hash_sk(parts) -%}
{#— HASHBYTES 回 varbinary(16)，CAST 成 BIGINT 取尾 8 位元組——確定性、全量重建後不變，
    與 BigQuery 版用 FARM_FINGERPRINT 的理由相同（見 dim_customer.sql 的代理鍵註解）。—#}
cast(hashbytes('MD5', concat({% for p in parts %}cast({{ p }} as varchar(32)){% if not loop.last %}, '|', {% endif %}{% endfor %})) as bigint)
{%- endmacro %}


{#— 安全除法：分母為 0 回 NULL（而非炸掉或回 0——NULL 在比較裡不成立，語意正確）。—#}

{% macro safe_div(numerator, denominator) %}{{ adapter.dispatch('safe_div', 'dw_credit_star')(numerator, denominator) }}{% endmacro %}

{% macro bigquery__safe_div(numerator, denominator) -%}
safe_divide({{ numerator }}, {{ denominator }})
{%- endmacro %}

{% macro default__safe_div(numerator, denominator) -%}
({{ numerator }} / nullif({{ denominator }}, 0))
{%- endmacro %}


{#— 真值旗標：BigQuery 有原生 BOOL，T-SQL 家族只有 bit。—#}
{#— 產出端用 bool_flag() 寫值、檢核端用 count_true() 數值，兩端必須成對使用。—#}

{% macro bool_flag(condition) %}{{ adapter.dispatch('bool_flag', 'dw_credit_star')(condition) }}{% endmacro %}

{% macro bigquery__bool_flag(condition) -%}
({{ condition }})
{%- endmacro %}

{% macro default__bool_flag(condition) -%}
cast(case when {{ condition }} then 1 else 0 end as bit)
{%- endmacro %}


{% macro count_true(column) %}{{ adapter.dispatch('count_true', 'dw_credit_star')(column) }}{% endmacro %}

{% macro bigquery__count_true(column) -%}
countif({{ column }})
{%- endmacro %}

{% macro default__count_true(column) -%}
sum(case when {{ column }} = 1 then 1 else 0 end)
{%- endmacro %}
