"""從倉儲匯出 BI 用的整齊資料集（Tableau／Power BI 皆可直接吃）。

刻意匯出**寬度小、粒度明確**的多張表，而不是一張大寬表：BI 工具端最常見的
錯誤就是拿一張混合粒度的寬表去做聚合，把「客戶月」和「客戶」混在一起算，
平均值於是被重複計數扭曲。每張表在檔頭註明粒度，儀表板端照粒度用。

比率一律**存分子分母、不存比率**（與倉儲層同一條規則）：BI 端要算使用率時
先各自加總再相除，直接對每列比率取平均會得到「平均的平均」，
小額與大額帳戶被當成等權。
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db import DATABASE, connect  # noqa: E402


def query_with_columns(sql: str) -> tuple[list[str], list[tuple]]:
    """欄名一律取自 cursor.description，不從 SQL 字串推。

    第一版用字串切 SELECT…FROM 推欄名，遇到 CTE 就抓錯段落——
    tier_migration.csv 的標頭因此變成 CTE 內層的欄位，標頭與資料對不上。
    這種錯不會報例外，只會讓儀表板把「前月等級」畫成「日期」。
    """
    with connect(DATABASE) as conn:
        cur = conn.cursor()
        cur.execute(sql)
        return [d[0] for d in cur.description], cur.fetchall()

OUT = Path(__file__).resolve().parent.parent / "bi" / "extract"

QUERIES: dict[str, tuple[str, str]] = {
    # 檔名: (粒度說明, SQL)
    "risk_tier_by_month": (
        "粒度＝風險等級 × 月份（一列一個等級一個月）",
        """
        SELECT d.date_key AS month_key, d.year_num, d.month_num,
               c.risk_tier,
               COUNT(*) AS customer_months,
               SUM(CAST(f.bill_amount AS BIGINT)) AS bill_amount_sum,
               SUM(CAST(f.credit_limit AS BIGINT)) AS credit_limit_sum,
               SUM(CAST(p.is_delinquent AS INT)) AS delinquent_months
          FROM dw.fact_monthly_statement f
          JOIN dw.dim_date d ON d.date_key = f.date_key
          JOIN dw.dim_customer c ON c.customer_sk = f.customer_sk
          JOIN dw.dim_payment_status p ON p.pay_status_key = f.pay_status_key
         GROUP BY d.date_key, d.year_num, d.month_num, c.risk_tier
        """),
    "tier_migration": (
        "粒度＝前月等級 × 本月等級（遷移矩陣，只有 SCD Type 2 答得出來）",
        """
        WITH t AS (
            SELECT f.date_key, c.client_id, c.risk_tier,
                   LAG(c.risk_tier) OVER (PARTITION BY c.client_id ORDER BY f.date_key) AS prev_tier
              FROM dw.fact_monthly_statement f
              JOIN dw.dim_customer c ON c.customer_sk = f.customer_sk)
        SELECT prev_tier, risk_tier AS curr_tier, COUNT(*) AS customer_months
          FROM t WHERE prev_tier IS NOT NULL
         GROUP BY prev_tier, risk_tier
        """),
    "default_by_tier": (
        "粒度＝觀測期末風險等級（一列一個等級）",
        """
        SELECT c.risk_tier, COUNT(*) AS customers,
               SUM(CAST(o.is_default AS INT)) AS defaults
          FROM dw.fact_default_outcome o
          JOIN dw.dim_customer c ON c.customer_sk = o.customer_sk
         WHERE c.is_current = 1
         GROUP BY c.risk_tier
        """),
    "version_counts": (
        "粒度＝版本數（一列一種「客戶總共被開了幾個版本」）",
        """
        SELECT versions, COUNT(*) AS customers FROM (
            SELECT client_id, COUNT(*) AS versions
              FROM dw.dim_customer GROUP BY client_id) v
         GROUP BY versions
        """),
    "quality_results": (
        "粒度＝品質規則 × 批次（讓儀表板能顯示資料品質，而不只有業務數字）",
        """
        SELECT rule_code, severity, verdict, rows_checked, rows_failed
          FROM dq.v_quality_report
        """),
}


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (grain, sql) in QUERIES.items():
        header, rows = query_with_columns(sql)
        path = OUT / f"{name}.csv"
        with open(path, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.writer(f)
            w.writerow(header)
            w.writerows(rows)
        print(f"✓ {path.name}（{len(rows)} 列）— {grain}")
    print(f"\n→ {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
