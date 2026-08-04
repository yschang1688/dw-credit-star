"""credit_dw_etl — 星狀綱要 ETL 的 Airflow 編排。

把 run_etl.py 的單機流程拆成可觀測、可重試的任務圖。編排不是把腳本
包成一個 task 就完事——這條 DAG 的存在理由是三個「腳本裡看不見」的語意：

1. **SCD2 的時序正確性顯式化**。逐月載入必須由舊到新，先載 9 月再載 4 月
   版本區間會錯亂。單機腳本用 for-loop 順序隱含這件事；這裡把它寫成
   task 依賴鏈（200504 >> 200505 >> … >> 200509），調度器層面就不可能亂序，
   任一月失敗，後面的月份不會帶著錯的維度版本繼續跑。
2. **品質稽核是道閘，不是報表**。quality_gate 在 ERROR 級規則失敗時讓
   DAG 失敗，下游（資料字典）不會在髒資料上產出。
3. **批次貫串與收尾對稱**。batch_id 經 XCom 傳遍全圖；finalize 用
   trigger_rule 保證成功標 SUCCEEDED、失敗標 FAILED，不留 RUNNING 殭屍批次。

冪等性沿用倉儲層既有設計（事實表先刪後插、SCD2 雜湊比對）——這保證
**單一輪之內**任務重試不產生重複列；Airflow 的任務會重試，不冪等的任務
配上重試等於自動化地製造重複資料。整條 pipeline 則是 full refresh 語意
（apply_schema 每輪重建綱要），重跑落地筆數不變是決定性重建的結果。
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta

from airflow.decorators import dag, task
from airflow.utils.trigger_rule import TriggerRule

REPO = os.environ.get("DW_REPO_ROOT", "/opt/dwrepo")
sys.path.insert(0, f"{REPO}/etl")

# 六個來源月，由舊到新（source_month_ix 6 → 1）。寫死而非查 dim_date，
# 因為 task graph 必須在解析期決定；月份集合由資料集決定，不會變。
MONTH_IX_OLD_TO_NEW = [6, 5, 4, 3, 2, 1]
OUTCOME_IX = 7

DEFAULT_ARGS = {
    "retries": 2,
    "retry_delay": timedelta(seconds=20),  # DB 容器暖機中的連線失敗靠重試吸收
}


@dag(
    dag_id="credit_dw_etl",
    description="來源快照 → 暫存區 → SCD2 維度 → 事實 → 品質閘 → 資料字典",
    schedule=None,  # 手動觸發；批次資料無自然排程，掛 cron 反而是假語意
    start_date=datetime(2026, 8, 1),
    catchup=False,
    default_args=DEFAULT_ARGS,
    tags=["dw", "t-sql", "scd2"],
)
def credit_dw_etl():

    @task
    def apply_schema() -> None:
        from db import DATABASE, SQL_DIR, run_script
        run_script(SQL_DIR / "01_schema.sql")
        for f in ("02_reference_data.sql", "03_procedures.sql", "04_quality_checks.sql"):
            run_script(SQL_DIR / f, database=DATABASE)

    @task
    def load_staging() -> dict:
        """CSV 快照 → 暫存區，並登記批次。回傳 batch 資訊走 XCom。"""
        import pandas as pd
        from db import DATABASE, connect, new_batch_id
        from run_etl import load_staging as _load

        csv = f"{REPO}/data/source_credit_clients.csv"
        if not os.path.exists(csv):
            raise FileNotFoundError(
                f"{csv} 不存在——在宿主機跑 etl/export_source_csv.py 產出來源快照")
        df = pd.read_csv(csv)

        batch_id = new_batch_id()
        with connect(DATABASE) as conn:
            conn.cursor().execute(
                "INSERT INTO dq.load_batch (load_batch_id, started_at, source_name, source_rows, status)"
                " VALUES (%s, SYSUTCDATETIME(), %s, %s, 'RUNNING')",
                (batch_id, "UCI credit clients（CSV 快照）", len(df)))
        n = _load(df, batch_id)
        return {"batch_id": batch_id, "source_rows": n}

    def month_task(ix: int):
        @task(task_id=f"load_month_ix{ix}")
        def _load_month(batch: dict) -> None:
            from db import DATABASE, connect, scalar
            date_key = scalar(
                "SELECT date_key FROM dw.dim_date WHERE source_month_ix = %s", (ix,))
            with connect(DATABASE) as conn:
                cur = conn.cursor()
                for proc in ("dw.usp_load_dim_customer_scd2",
                             "dw.usp_load_fact_monthly_statement"):
                    cur.callproc(proc, (date_key, batch["batch_id"]))
                    while cur.nextset():
                        pass
            facts = scalar("SELECT COUNT(*) FROM dw.fact_monthly_statement WHERE date_key=%s",
                           (date_key,))
            versions = scalar("SELECT COUNT(*) FROM dw.dim_customer")
            print(f"{date_key}（第 {ix} 近月）→ 事實 {facts:,} 列｜維度累計 {versions:,} 版本")
        return _load_month

    @task
    def load_outcome(batch: dict) -> None:
        from db import DATABASE, connect, scalar
        outcome_key = scalar(
            "SELECT date_key FROM dw.dim_date WHERE source_month_ix = %s", (OUTCOME_IX,))
        with connect(DATABASE) as conn:
            cur = conn.cursor()
            cur.callproc("dw.usp_load_fact_default_outcome", (outcome_key, batch["batch_id"]))
            while cur.nextset():
                pass

    @task
    def quality_gate(batch: dict) -> None:
        """跑 12 條品質規則；ERROR 級失敗即讓 DAG 失敗。WARN 如實列出、不擋。"""
        from db import DATABASE, connect, query
        with connect(DATABASE) as conn:
            cur = conn.cursor()
            cur.callproc("dq.usp_run_quality_checks",
                         (batch["batch_id"], batch["source_rows"]))
            while cur.nextset():
                pass
        report = query(
            "SELECT rule_code, severity, verdict, rows_failed, sample_detail"
            "  FROM dq.v_quality_report WHERE load_batch_id=%s ORDER BY rule_code",
            (batch["batch_id"],))
        fails = []
        for code, sev, verdict, failed, detail in report:
            mark = {"PASS": "✓", "WARN": "△", "FAIL": "✗"}[verdict]
            print(f"{mark} {code} [{sev}] {verdict} 失敗 {failed} {detail or ''}")
            if verdict == "FAIL":
                fails.append(code)
        if fails:
            raise RuntimeError(f"ERROR 級規則未過：{', '.join(fails)}")

    @task
    def gen_data_dictionary() -> None:
        """品質閘之後才產字典——文件永遠描述通過稽核的那版綱要。"""
        import gen_data_dictionary as g
        g.main()

    @task(trigger_rule=TriggerRule.ALL_DONE)
    def finalize(batch: dict, **ctx) -> None:
        """成功標 SUCCEEDED、失敗標 FAILED；不留 RUNNING 殭屍批次。"""
        from db import DATABASE, connect
        dr = ctx["dag_run"]
        failed = any(ti.state == "failed" for ti in dr.get_task_instances())
        status = "FAILED" if failed else "SUCCEEDED"
        with connect(DATABASE) as conn:
            conn.cursor().execute(
                "UPDATE dq.load_batch SET finished_at=SYSUTCDATETIME(), status=%s"
                " WHERE load_batch_id=%s", (status, batch["batch_id"]))
        print(f"批次 {batch['batch_id']} → {status}")

    schema = apply_schema()
    batch = load_staging()
    schema >> batch

    # SCD2 時序：由舊到新串成鏈，亂序在圖上就不可能發生
    prev = batch
    for ix in MONTH_IX_OLD_TO_NEW:
        cur = month_task(ix)(batch)
        prev >> cur
        prev = cur

    outcome = load_outcome(batch)
    gate = quality_gate(batch)
    prev >> outcome >> gate >> gen_data_dictionary()
    gate >> finalize(batch)


credit_dw_etl()
