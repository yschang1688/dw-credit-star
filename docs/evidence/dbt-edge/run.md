# dbt × Azure SQL Edge（本機 T-SQL）實跑存證

> 產生於 2026-09-15。同一個 dbt 專案的第二個 target：`--target edge`，
> 打的是 quickstart 起的本機 Azure SQL Edge 容器——與預存程序版**同庫並存**
> （dbt 產物在 `dbt_stg`／`dbt_dw`，預存程序版在 `stg`／`dw`）。
> 這個 target 的存在理由是 **dbt-fabric 前置驗證**：dbt-sqlserver 與 dbt-fabric
> 講同一種 T-SQL 方言、共用 `macros/cross_db.sql` 的 `default__` 實作。

## 執行摘要

```
dbt=1.12.0, adapter: sqlserver=1.11.1
Found 5 models, 1 analysis, 5 seeds, 34 data tests, 1 source, 573 macros
Finished running 5 seeds, 3 table models, 34 data tests, 2 view models
  in 0 hours 1 minutes and 42.79 seconds (102.79s).
Done. PASS=44 WARN=0 ERROR=0 SKIP=0 NO-OP=0 REUSED=0 TOTAL=44
```

同日重跑第二次仍 44/44——全量重建冪等（代理鍵是確定性雜湊，重建後不變）。

## 產出物

| schema | 物件 | 列數 |
|---|---|---:|
| dbt_stg | stg_credit_clients | （view） |
| dbt_stg | stg_monthly_snapshot | （view） |
| dbt_dw | dim_customer | 51,110 |
| dbt_dw | dim_date ＋ 四張碼值維度（seeds） | 7／2／7／4／12 |
| dbt_dw | fact_monthly_statement | 180,000 |
| dbt_dw | fact_default_outcome | 30,000 |

中文標籤驗證：`dim_date.month_name_zh = '2005年4月'`、`dim_education.education_desc = '研究所'`
（NVARCHAR 分流生效，見 `dbt_project.yml` seeds 註解——預設 VARCHAR 會靜默變問號）。

## 與預存程序版同庫對帳

查詢：[`dbt/analyses/reconcile_edge_dbt_vs_procs.sql`](../../../dbt/analyses/reconcile_edge_dbt_vs_procs.sql)。
同庫對帳的特權是沒有匯出與序列化這一層懷疑——差異就是差異。

```
1 列數三件組（180,000／51,110／30,000）: 差異列 0 ✓
2 SCD2 語意（每客戶每月的有效版本 risk_tier）: 差異列 0 ✓
3 逐月量值總額（bill／payment）: 差異列 0 ✓
```

對帳過程本身抓到一個真實教訓：第一版對帳查詢對兩邊套了同一個區間述詞，
憑空冒出 21,110 列「差異」——恰好等於非當前版本數。真因是**端點慣例不同**
（預存程序版含端、dbt 版排他端），不是資料錯。述詞各用各的之後歸零。
詳見對帳查詢內的註解。

## dbt docs（lineage）

`dbt docs generate --target edge` 產出 `target/index.html`＋`catalog.json`：
source（`stg.credit_clients`，與預存程序版共用的落地表）→ staging → marts
的血緣圖與逐欄文件，零額外維護——血緣是從 `ref()`／`source()` 推出來的，
不是手畫的圖，改模型不會讓文件過期。
