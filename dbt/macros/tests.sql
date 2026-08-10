{#
  自訂通用測試。

  刻意不引入 dbt_utils／dbt_expectations：那兩個套件要 `dbt deps` 拉網路，
  而這個專案的賣點之一是「完整重現」——多一層網路相依就多一個
  「別人跑不起來」的理由。四個測試自己寫不到 40 行。
#}

{% test unique_combination_of_columns(model, columns) %}
    -- 粒度守衛：宣告的粒度組合必須唯一。違反時每個彙總都會悄悄變成倍數。
    select {{ columns | join(', ') }}, count(*) as n
    from {{ model }}
    group by {{ columns | join(', ') }}
    having count(*) > 1
{% endtest %}


{% test expect_row_count(model, count) %}
    -- 列數是最便宜的完整性檢查。少載一個月不會報錯，只會讓報表數字變小。
    select {{ count }} as expected, count(*) as actual
    from {{ model }}
    having count(*) <> {{ count }}
{% endtest %}


{% test dbt_utils_free_exactly_one_current(model) %}
    -- SCD2：每個自然鍵恰好一個當前版本。
    select client_id, countif(is_current) as current_versions
    from {{ model }}
    group by client_id
    having countif(is_current) <> 1
{% endtest %}


{% test scd2_no_overlapping_versions(model) %}
    -- SCD2：同一客戶的版本區間不得重疊。重疊的後果是「同一時點兩個版本都有效」，
    -- 事實表的時點關聯會複製列——180,000 悄悄變成 200,000 之類。
    select a.client_id, a.valid_from_date as a_from, b.valid_from_date as b_from
    from {{ model }} as a
    join {{ model }} as b
      on  a.client_id = b.client_id
      and a.valid_from_date < b.valid_from_date
      and b.valid_from_date < a.valid_to_date
{% endtest %}


{% test dbt_expectations_free_non_negative(model, column_name) %}
    select {{ column_name }}
    from {{ model }}
    where {{ column_name }} < 0
{% endtest %}
