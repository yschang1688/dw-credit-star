"""跨雲可攜的守門測試：批次切分與「資料庫脈絡批次」的辨識。

為什麼這件事需要守門
--------------------
同一套 T-SQL 要跑在三種託管形態上，差別只在**資料庫是誰建的**：容器與
AWS RDS 由腳本自己 `CREATE DATABASE` 再 `USE`；Azure SQL Database 的資料庫
是一個 Terraform 資源，那兩句在上面是語法錯誤。

處理方式是執行時略過那兩種批次。這個判斷一旦寫鬆或寫緊，**症狀都不是
「你連錯資料庫了」**：

- 寫緊（漏判）→ `USE OtherDb` 照送，後續 DDL 全部落到另一個資料庫。
  2026-08-10 實跑就踩到：`01_schema.sql` 檔頭有一整段區塊註解、
  `02_reference_data.sql` 的 `USE` 前面也有註解，於是「整批只有一句 USE」
  的比對不成立。錯誤訊息是 **`dim_date` 主鍵重複**——指不到真因。
- 寫鬆（誤判）→ 含有 `USE` 或 `CREATE DATABASE` 字樣的**真 DDL** 被整批丟掉，
  綱要少了一塊卻沒有任何錯誤，直到某條查詢找不到欄位才爆。

所以下面同時測「該略過的有略過」與「不該略過的沒被略過」，缺一邊都是假綠。
"""
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "etl"))

from db import is_context_batch, split_batches, strip_comments  # noqa: E402


# ── 一、該略過的：純粹切換／建立資料庫脈絡 ──────────────────────

@pytest.mark.parametrize("batch", [
    "USE CreditRiskDW;",
    "use creditriskdw",
    "USE [CreditRiskDW];",
    "  USE CreditRiskDW ;  ",
    "IF DB_ID('CreditRiskDW') IS NULL\n    CREATE DATABASE CreditRiskDW;",
    "CREATE DATABASE CreditRiskDW",
])
def test_context_batches_are_recognised(batch: str) -> None:
    assert is_context_batch(batch)


@pytest.mark.parametrize("prefix", [
    "/*  檔頭區塊註解\n    好幾行\n*/\n\n",          # 01_schema.sql 的實際情形
    "-- 單行註解\n",
    "-- 一行\n-- 兩行\n\n",
    "/* 行內 */ ",
])
def test_leading_comments_do_not_hide_a_context_batch(prefix: str) -> None:
    """這條就是 2026-08-10 實跑抓到的缺陷的回歸測試。"""
    assert is_context_batch(prefix + "USE CreditRiskDW;")
    assert is_context_batch(prefix + "IF DB_ID('X') IS NULL\n CREATE DATABASE X;")


# ── 二、不該略過的：真 DDL／DML 一律保留 ────────────────────────

@pytest.mark.parametrize("batch", [
    "CREATE TABLE dw.dim_customer (customer_sk INT)",
    "INSERT INTO dw.dim_date (date_key) VALUES (200509)",
    "SELECT * FROM stg.credit_clients WHERE usage_ratio > 1",   # 欄名含 use
    "EXEC('CREATE SCHEMA dw')",
    "CREATE PROCEDURE dw.usp_x AS BEGIN\n  USE_HINT_PLACEHOLDER\nEND",
    "-- USE CreditRiskDW（這行只是註解）\nCREATE TABLE dw.t (a INT)",
    "CREATE TABLE dw.t (a INT)\nGO_NOT_A_SEPARATOR",
])
def test_real_statements_are_never_skipped(batch: str) -> None:
    assert not is_context_batch(batch)


def test_a_batch_that_does_more_than_switch_context_is_kept() -> None:
    """`USE` 後面接了真敘述的批次不得整批丟掉——那會靜默少掉一段綱要。"""
    assert not is_context_batch("USE CreditRiskDW;\nCREATE TABLE dw.t (a INT);")


# ── 三、註解剝除本身 ────────────────────────────────────────────

def test_strip_comments_removes_both_forms_but_keeps_code() -> None:
    sql = "/* 區塊 */ SELECT 1 -- 行末\nFROM t"
    out = strip_comments(sql)
    assert "區塊" not in out and "行末" not in out
    assert "SELECT 1" in out and "FROM t" in out


# ── 四、GO 切批次（既有行為，一併釘住）────────────────────────

def test_go_splits_batches_only_when_alone_on_a_line() -> None:
    script = "SELECT 1\nGO\nSELECT 2\nGO\nSELECT 'no go here'\n"
    assert len(split_batches(script)) == 3


def test_the_word_go_inside_a_statement_is_not_a_separator() -> None:
    """探針：若 GO 的比對沒綁行首，這個字串會被腰斬成兩批而語法錯誤。"""
    script = "SELECT 'GO' AS x, category FROM t WHERE name = 'GO'"
    assert len(split_batches(script)) == 1


# ── 五、實際腳本的可攜性稽核 ───────────────────────────────────

SQL_FILES = sorted((ROOT / "sql").glob("*.sql"))


def test_every_sql_file_has_at_least_one_batch() -> None:
    assert SQL_FILES
    for f in SQL_FILES:
        assert split_batches(f.read_text(encoding="utf-8"))


@pytest.mark.parametrize("path", SQL_FILES, ids=lambda p: p.name)
def test_context_statements_live_in_their_own_batch(path: Path) -> None:
    """`USE`／`CREATE DATABASE` 必須自成一批，否則在 azure-sql 上無法只略過它。

    這是對**寫 SQL 的人**的約束：把 `USE` 和真 DDL 塞進同一批，
    可攜層就只有兩個選擇——連 DDL 一起丟，或連 USE 一起送，兩個都是錯的。
    """
    for i, batch in enumerate(split_batches(path.read_text(encoding="utf-8")), 1):
        body = strip_comments(batch).strip()
        if not body:
            continue
        head = body.split("\n")[0].strip().upper()
        if head.startswith("USE ") or head.startswith("CREATE DATABASE"):
            assert is_context_batch(batch), (
                f"{path.name} 第 {i} 批以 USE／CREATE DATABASE 開頭卻不是純脈絡批次——"
                "請把它獨立成一批（前後加 GO），否則 azure-sql 平台無法安全略過")


def test_azure_sql_unsupported_features_are_absent() -> None:
    """Azure SQL Database 不支援的伺服器層功能，出現即代表可攜性已破。"""
    banned = ("BACKUP ", "RESTORE ", "sp_configure", "xp_cmdshell",
              "FILEGROUP", "CREATE LOGIN", "USE master", "OPENROWSET", "BULK INSERT")
    for f in SQL_FILES:
        body = strip_comments(f.read_text(encoding="utf-8")).upper()
        for token in banned:
            assert token.upper() not in body, f"{f.name} 使用了 Azure SQL Database 不支援的 {token}"
