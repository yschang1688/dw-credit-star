"""資料庫連線與 SQL 腳本執行。

pymssql 不認得 `GO`——那是 sqlcmd 的批次分隔符而非 T-SQL 語法，
所以要自己切批次。切錯會讓 `CREATE SCHEMA` 這類必須獨立成批的語句失敗。
"""
from __future__ import annotations

import os
import re
import uuid
from contextlib import contextmanager
from pathlib import Path

import pymssql

ROOT = Path(__file__).resolve().parent.parent
SQL_DIR = ROOT / "sql"

# 連線參數一律可由環境變數覆寫。
# 預設值是**本機開發容器的一次性憑證**：容器只綁 127.0.0.1:11433、不對外，
# 且隨 `docker rm` 一起消失。任何非本機環境都必須以 DW_PASSWORD 覆寫，
# 這裡留預設值只是為了讓 quickstart 能一行跑起來。
CONN = dict(
    server=os.environ.get("DW_HOST", "127.0.0.1"),
    port=int(os.environ.get("DW_PORT", "11433")),
    user=os.environ.get("DW_USER", "sa"),
    password=os.environ.get("DW_PASSWORD", "DwStar!2026dev"),
)
DATABASE = os.environ.get("DW_DATABASE", "CreditRiskDW")

# 行首單獨的 GO（可帶大小寫與尾隨空白），才是批次分隔符；
# 字串或註解裡的 "go" 不算，所以綁定行首並要求整行只有它。
_GO = re.compile(r"^\s*GO\s*(?:--.*)?$", re.IGNORECASE | re.MULTILINE)


@contextmanager
def connect(database: str | None = None, autocommit: bool = True):
    kwargs = dict(CONN)
    if database:
        kwargs["database"] = database
    conn = pymssql.connect(**kwargs, autocommit=autocommit)
    try:
        yield conn
    finally:
        conn.close()


def split_batches(script: str) -> list[str]:
    return [b.strip() for b in _GO.split(script) if b.strip()]


def run_script(path: Path | str, database: str | None = None, echo: bool = True) -> None:
    """執行 .sql 檔。逐批送出，失敗時報出批次序號與前兩行，方便定位。"""
    path = Path(path)
    script = path.read_text(encoding="utf-8")
    batches = split_batches(script)

    with connect(database) as conn:
        cur = conn.cursor()
        for i, batch in enumerate(batches, 1):
            try:
                cur.execute(batch)
                # PRINT 的輸出在 pymssql 走訊息通道，逐批取出才看得到
                while cur.nextset():
                    pass
            except Exception as exc:
                head = "\n".join(batch.splitlines()[:2])
                raise RuntimeError(
                    f"{path.name} 第 {i}/{len(batches)} 批失敗：{exc}\n批次開頭：{head}"
                ) from exc
    if echo:
        print(f"  ✓ {path.name}（{len(batches)} 批）")


def query(sql: str, params=None, database: str | None = DATABASE) -> list[tuple]:
    with connect(database) as conn:
        cur = conn.cursor()
        cur.execute(sql, params or ())
        return cur.fetchall()


def scalar(sql: str, params=None, database: str | None = DATABASE):
    rows = query(sql, params, database)
    return rows[0][0] if rows else None


def new_batch_id() -> str:
    return str(uuid.uuid4())
