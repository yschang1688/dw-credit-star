"""ETL 編排：來源 → 暫存區 → 維度（SCD2）→ 事實 → 品質稽核。

設計重點
--------
1. **逐月由舊到新載入**。SCD Type 2 是有時序的：先載 9 月再載 4 月，
   版本區間會錯亂。順序在維度建模不是效能問題，是正確性問題。
2. **批次識別碼貫串全程**。每列資料都帶得回「哪一次執行載進來的」，
   出事時才追得到。
3. **可重跑**。同一批次重跑不會產生重複列（事實表先刪後插、SCD2 以雜湊比對）。
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pandas as pd
import pymssql

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db import DATABASE, SQL_DIR, connect, new_batch_id, query, run_script, scalar  # noqa: E402

SOURCE_REPO = Path.home() / "credit-risk-decision-policy"


def extract() -> pd.DataFrame:
    """取來源資料。

    兩條路徑刻意共用同一個函式，避免資料分岔：
    - 本機：從既有的信用風險專案讀（OpenML 快取），保持單一來源。
    - 容器／叢集：讀 `DW_SOURCE_CSV` 指向的快照——容器裡看不到隔壁 repo，
      快照由 `etl/export_source_csv.py` 在宿主機從同一個 load() 產出。
    """
    csv = os.environ.get("DW_SOURCE_CSV")
    if csv:
        df = pd.read_csv(csv)
        if "client_id" not in df.columns:
            df.insert(0, "client_id", df.index + 1)
        return df

    sys.path.insert(0, str(SOURCE_REPO / "src"))
    from data import load  # type: ignore

    df = load()
    df = df.reset_index(drop=True)
    df.insert(0, "client_id", df.index + 1)
    return df


def load_staging(df: pd.DataFrame, batch_id: str) -> int:
    cols = ["client_id", "limit_bal", "sex", "education", "marriage", "age",
            *[f"pay_{i}" for i in range(1, 7)],
            *[f"bill_amt{i}" for i in range(1, 7)],
            *[f"pay_amt{i}" for i in range(1, 7)],
            "default"]
    data = df[cols].itertuples(index=False, name=None)
    rows = [(*r[:-1], int(r[-1]), batch_id) for r in data]

    placeholders = ", ".join(["%s"] * (len(cols) + 1))
    sql = f"""INSERT INTO stg.credit_clients
              (client_id, limit_bal, sex, education, marriage, age,
               pay_1,pay_2,pay_3,pay_4,pay_5,pay_6,
               bill_amt1,bill_amt2,bill_amt3,bill_amt4,bill_amt5,bill_amt6,
               pay_amt1,pay_amt2,pay_amt3,pay_amt4,pay_amt5,pay_amt6,
               default_next_month, load_batch_id)
              VALUES ({placeholders})"""

    with connect(DATABASE, autocommit=False) as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM stg.credit_clients")
        # executemany 在 pymssql 會逐列送出；3 萬列分批 commit 避免交易過大
        CHUNK = 5000
        for i in range(0, len(rows), CHUNK):
            cur.executemany(sql, rows[i:i + CHUNK])
            conn.commit()
    return len(rows)


def main() -> int:
    batch_id = new_batch_id()
    print(f"批次 {batch_id}\n")

    print("[1/5] 套用綱要與參考資料")
    for f in ("01_schema.sql",):
        run_script(SQL_DIR / f)
    for f in ("02_reference_data.sql", "03_procedures.sql", "04_quality_checks.sql"):
        run_script(SQL_DIR / f, database=DATABASE)

    print("\n[2/5] 擷取來源")
    df = extract()
    print(f"  來源 {len(df):,} 列 × {df.shape[1]} 欄")

    with connect(DATABASE) as conn:
        conn.cursor().execute(
            "INSERT INTO dq.load_batch (load_batch_id, started_at, source_name, source_rows, status)"
            " VALUES (%s, SYSUTCDATETIME(), %s, %s, 'RUNNING')",
            (batch_id, "UCI default of credit card clients (OpenML)", len(df)))

    print("\n[3/5] 載入暫存區")
    n = load_staging(df, batch_id)
    print(f"  暫存區 {n:,} 列")

    # 由舊到新：source_month_ix 6 → 1
    months = query("SELECT date_key, source_month_ix FROM dw.dim_date"
                   " WHERE source_month_ix BETWEEN 1 AND 6 ORDER BY source_month_ix DESC")

    print("\n[4/5] 逐月載入維度與事實（由舊到新）")
    with connect(DATABASE) as conn:
        cur = conn.cursor()
        for date_key, ix in months:
            cur.callproc("dw.usp_load_dim_customer_scd2", (date_key, batch_id))
            while cur.nextset():
                pass
            cur.callproc("dw.usp_load_fact_monthly_statement", (date_key, batch_id))
            while cur.nextset():
                pass
            versions = scalar("SELECT COUNT(*) FROM dw.dim_customer")
            facts = scalar("SELECT COUNT(*) FROM dw.fact_monthly_statement WHERE date_key=%s", (date_key,))
            print(f"  {date_key}（第 {ix} 近月）→ 事實 {facts:,} 列｜維度累計 {versions:,} 版本")

        outcome_key = scalar("SELECT date_key FROM dw.dim_date WHERE source_month_ix = 7")
        cur.callproc("dw.usp_load_fact_default_outcome", (outcome_key, batch_id))
        while cur.nextset():
            pass

    print("\n[5/5] 資料品質稽核")
    with connect(DATABASE) as conn:
        cur = conn.cursor()
        cur.callproc("dq.usp_run_quality_checks", (batch_id, len(df)))
        while cur.nextset():
            pass
        cur.execute("UPDATE dq.load_batch SET finished_at=SYSUTCDATETIME(), status='SUCCEEDED'"
                    " WHERE load_batch_id=%s", (batch_id,))

    report = query("""SELECT rule_code, severity, verdict, rows_checked, rows_failed, sample_detail
                        FROM dq.v_quality_report WHERE load_batch_id=%s
                       ORDER BY CASE verdict WHEN 'FAIL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, rule_code""",
                   (batch_id,))
    print(f"\n{'規則':26s} {'嚴重度':7s} {'判定':5s} {'檢核':>8s} {'失敗':>8s}")
    fails = 0
    for code, sev, verdict, checked, failed, detail in report:
        mark = {"PASS": "✓", "WARN": "△", "FAIL": "✗"}[verdict]
        print(f"{mark} {code:24s} {sev:7s} {verdict:5s} {checked:8,d} {failed:8,d}  {detail or ''}")
        if verdict == "FAIL":
            fails += 1

    print(f"\n{'✗ 有 ' + str(fails) + ' 條 ERROR 級規則未過' if fails else '✓ 所有 ERROR 級規則通過'}")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
