"""把來源資料落成 CSV 快照，給容器化 Airflow 用。

單機路徑（run_etl.py）直接 import 隔壁 repo 的 loader；容器裡看不到那個 repo，
所以 Airflow 路徑改吃 `data/source_credit_clients.csv`。快照由本腳本在宿主機產出，
兩條路徑共用同一個來源函式，資料不會分岔。
"""
from __future__ import annotations

from pathlib import Path

from run_etl import extract

OUT = Path(__file__).resolve().parent.parent / "data" / "source_credit_clients.csv"


def main() -> None:
    df = extract()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(OUT, index=False)
    print(f"✓ {OUT}（{len(df):,} 列 × {df.shape[1]} 欄）")


if __name__ == "__main__":
    main()
