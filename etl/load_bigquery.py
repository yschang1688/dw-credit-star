"""把來源快照載進 BigQuery 的 raw dataset（dbt 的上游）。

為什麼不用 `bq load`
--------------------
`bq` 是 gcloud CLI 的一部分。dbt-bigquery 本身走 REST API（`google-cloud-bigquery`），
**不需要 CLI**——CLI 唯一不可取代的用途是取得應用程式預設憑證（ADC）。
既然 `google-cloud-bigquery` 已經在 dbt 的相依裡，載入這一步就沒有理由再多要求一個 CLI。

這樣做的附帶好處：欄位重新命名與型別在**程式裡明確寫死**，而不是靠
`bq load --autodetect` 猜。autodetect 猜錯型別不會報錯，只會讓下游的
`cast` 悄悄產生 NULL——那正是這個專案在講的那種「不會報錯的錯」。

用法（需先 `gcloud auth application-default login`）：
    ./.venv-dbt/bin/python etl/load_bigquery.py --project <PROJECT_ID> [--location asia-east1]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CSV = ROOT / "data" / "source_credit_clients.csv"

# 來源 CSV 的目標欄叫 `default`（UCI 原始命名）。
# SQL Server 版在 INSERT 時改名為 default_next_month；這裡做同一件事，
# 兩邊的暫存層欄名才對得起來——對不起來的話，跨引擎對帳比的就是兩份不同的東西。
# 另外 `default` 在 SQL 是保留字，留著它會逼得每個查詢都要跳脫。
RENAME = {"default": "default_next_month"}


def build_schema(bigquery):
    """明確宣告綱要，不用 autodetect。

    金額用 NUMERIC 而非 FLOAT64：這是錢。浮點數的累加誤差在單筆看不出來，
    在 18 萬列的 SUM 上就會跟 SQL Server 版的 DECIMAL(14,2) 對不起來，
    而對帳對不起來時你會先懷疑邏輯、最後才想到型別。
    """
    F = bigquery.SchemaField
    num = [F("limit_bal", "NUMERIC")]
    num += [F(f"bill_amt{i}", "NUMERIC") for i in range(1, 7)]
    num += [F(f"pay_amt{i}", "NUMERIC") for i in range(1, 7)]
    ints = [F("client_id", "INT64", mode="REQUIRED"),
            F("sex", "INT64"), F("education", "INT64"), F("marriage", "INT64"),
            F("age", "INT64"), F("default_next_month", "INT64")]
    ints += [F(f"pay_{i}", "INT64") for i in range(1, 7)]
    # 欄位順序必須與寫出的 CSV 一致
    order = ["client_id", "limit_bal", "sex", "education", "marriage", "age",
             *[f"pay_{i}" for i in range(1, 7)],
             *[f"bill_amt{i}" for i in range(1, 7)],
             *[f"pay_amt{i}" for i in range(1, 7)],
             "default_next_month"]
    by_name = {f.name: f for f in num + ints}
    return [by_name[n] for n in order]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--location", default="asia-east1")
    ap.add_argument("--dataset", default="credit_dw_raw")
    ap.add_argument("--table", default="credit_clients")
    ap.add_argument("--teardown", action="store_true",
                    help="刪除 raw 與 dbt 產出的 dataset，並實查歸零")
    a = ap.parse_args()

    import pandas as pd
    from google.cloud import bigquery

    if a.teardown:
        client = bigquery.Client(project=a.project, location=a.location)
        for ds in (a.dataset, "credit_dw", "credit_dw_stg"):
            client.delete_dataset(f"{a.project}.{ds}", delete_contents=True, not_found_ok=True)
            print(f"  刪除 {a.project}.{ds}")
        # 「指令沒報錯」與「雲端帳戶裡沒有東西」是兩件事——只有實查算數
        left = [d.dataset_id for d in client.list_datasets(project=a.project)]
        print(f"實查剩餘 dataset：{left or '（空）'}")
        return 0 if not left else 1

    if not CSV.exists():
        sys.exit(f"找不到 {CSV}——先跑 ./.venv/bin/python etl/export_source_csv.py")

    df = pd.read_csv(CSV).rename(columns=RENAME)
    missing = {"client_id", "default_next_month"} - set(df.columns)
    if missing:
        sys.exit(f"來源 CSV 缺少欄位 {missing}——export 端可能改過欄名")

    client = bigquery.Client(project=a.project, location=a.location)

    ds_id = f"{a.project}.{a.dataset}"
    ds = bigquery.Dataset(ds_id)
    ds.location = a.location
    client.create_dataset(ds, exists_ok=True)
    print(f"dataset {ds_id}（{a.location}）就緒")

    schema = build_schema(bigquery)
    ordered = df[[f.name for f in schema]]

    job = client.load_table_from_dataframe(
        ordered,
        f"{ds_id}.{a.table}",
        job_config=bigquery.LoadJobConfig(
            schema=schema,
            write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,  # 可重跑
        ),
    )
    job.result()

    tbl = client.get_table(f"{ds_id}.{a.table}")
    print(f"✓ {ds_id}.{a.table}：{tbl.num_rows:,} 列 × {len(tbl.schema)} 欄")
    if tbl.num_rows != len(df):
        sys.exit(f"載入列數 {tbl.num_rows} 與來源 {len(df)} 不符")
    print("  來源列數一致——可以接著跑 dbt seed / run / test")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
