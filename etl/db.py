"""資料庫連線與 SQL 腳本執行。

pymssql 不認得 `GO`——那是 sqlcmd 的批次分隔符而非 T-SQL 語法，
所以要自己切批次。切錯會讓 `CREATE SCHEMA` 這類必須獨立成批的語句失敗。

平台可攜（`DW_PLATFORM`）
------------------------
同一套綱要與 ETL 要能跑在三種託管形態上，差別只在**資料庫是誰建的**：

- `sqlserver`（預設）：本機容器與 AWS RDS for SQL Server。伺服器層可用，
  由 `01_schema.sql` 自己 `CREATE DATABASE` 再 `USE`。
- `azure-sql`：Azure SQL Database 是**單一資料庫即一個資源**，
  資料庫由 Terraform 建立；`CREATE DATABASE`／`USE` 在這裡是**語法不支援**
  （T-SQL 只能在 master 上 CREATE DATABASE，連上使用者資料庫後兩者皆會報錯）。

處理方式刻意選「執行時略過那兩種批次」而非「維護第二份 SQL」：
兩份 SQL 會漂移，而漂移不會有任何錯誤訊息，只會讓某一朵雲上的綱要悄悄變成舊版。
略過的批次會印出來，不靜默。
"""
from __future__ import annotations

import os
import re
import uuid
from contextlib import contextmanager
from pathlib import Path

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

PLATFORMS = ("sqlserver", "azure-sql")
PLATFORM = os.environ.get("DW_PLATFORM", "sqlserver")
if PLATFORM not in PLATFORMS:
    raise SystemExit(f"DW_PLATFORM 只能是 {PLATFORMS} 之一，實得 {PLATFORM!r}")

# 資料庫由外部（IaC）建立、連線時直接指定的平台。這類平台上，
# 腳本裡的 CREATE DATABASE／USE 不是「多餘」而是「會報錯」。
DB_PROVISIONED_EXTERNALLY = PLATFORM in ("azure-sql",)

# 行首單獨的 GO（可帶大小寫與尾隨空白），才是批次分隔符；
# 字串或註解裡的 "go" 不算，所以綁定行首並要求整行只有它。
_GO = re.compile(r"^\s*GO\s*(?:--.*)?$", re.IGNORECASE | re.MULTILINE)

# 「整個批次只有一句 USE」或「只有 CREATE DATABASE（可含 IF DB_ID 保護）」。
# 綁定整批而非逐行比對：真正的 DDL 裡若出現 USE 字樣（欄位名、註解、字串），
# 逐行比對會誤刪整批 DDL——那會是一個很難察覺的資料損壞來源。
_CONTEXT_BATCH = re.compile(
    r"""^\s*
        (?:IF\s+DB_ID\s*\(.*?\)\s+IS\s+NULL\s+)?     # 可選的存在性保護
        (?:CREATE\s+DATABASE\s+\[?\w+\]?|USE\s+\[?\w+\]?)
        \s*;?\s*$""",
    re.IGNORECASE | re.VERBOSE | re.DOTALL)

# 比對前要先剝註解。踩過的坑（2026-08-10 實跑抓到）：`01_schema.sql` 的第一批
# 前面有一整段檔頭區塊註解、`02_reference_data.sql` 的 `USE` 前面也有註解，
# 於是「整批只有一句 USE」的比對不成立、批次照送——**在 azure-sql 模式下
# 那句 USE 會把後續 DDL 全部導去另一個資料庫**。症狀是主鍵重複，
# 而不是「你連錯資料庫了」，光看錯誤訊息完全指不到真因。
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
_LINE_COMMENT = re.compile(r"--[^\n]*")


def strip_comments(sql: str) -> str:
    return _LINE_COMMENT.sub("", _BLOCK_COMMENT.sub("", sql))


@contextmanager
def connect(database: str | None = None, autocommit: bool = True):
    # pymssql 刻意延後到這裡才匯入：本模組的另一半（批次切分、脈絡批次辨識）
    # 是純文字處理，不該為了驗那半邊而要求安裝資料庫驅動。
    # 這不是潔癖——CI 的可攜性關卡只裝 pytest，模組層 import 會讓它整個收集失敗
    # （2026-08-10 CI 當場抓到；本機 .venv 裡有 pymssql 所以看不出來，
    #  與 Airflow DagBag 那次是同一種「本機環境掩蓋的錯」）。
    import pymssql

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


def is_context_batch(batch: str) -> bool:
    """這一批是否只是在切換／建立資料庫脈絡（USE／CREATE DATABASE）。"""
    return bool(_CONTEXT_BATCH.match(strip_comments(batch)))


def run_script(path: Path | str, database: str | None = None, echo: bool = True) -> None:
    """執行 .sql 檔。逐批送出，失敗時報出批次序號與前兩行，方便定位。"""
    path = Path(path)
    script = path.read_text(encoding="utf-8")
    batches = split_batches(script)

    skipped = 0
    if DB_PROVISIONED_EXTERNALLY:
        kept = [b for b in batches if not is_context_batch(b)]
        skipped = len(batches) - len(kept)
        batches = kept

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
        note = f"，略過 {skipped} 批資料庫脈絡（{PLATFORM}：資料庫由 IaC 建立）" if skipped else ""
        print(f"  ✓ {path.name}（{len(batches)} 批{note}）")


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
