"""從資料庫的系統目錄產出資料字典。

為什麼要用 metadata 產而不是手寫：手寫的資料字典一定會過期——
欄位改了沒人記得改文件，久了就沒人信。從 sys.tables / sys.columns 讀，
文件與綱要不可能不一致。這是「資料綱要與資料字典維護」的實際做法。
"""
from __future__ import annotations

import sys
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db import query  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "docs" / "data_dictionary.md"

SCHEMA_PURPOSE = {
    "stg": "暫存區：與來源同構，不做轉換，只負責落地與可重跑",
    "dw": "維度與事實：星狀綱要本體",
    "dq": "資料品質：稽核規則、結果與批次紀錄",
}


def main() -> None:
    tables = query("""
        SELECT s.name, t.name, ISNULL(p.rows, 0)
          FROM sys.tables t
          JOIN sys.schemas s ON s.schema_id = t.schema_id
          LEFT JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
         ORDER BY s.name, t.name""")

    columns = query("""
        SELECT s.name, t.name, c.column_id, c.name,
               ty.name, c.max_length, c.precision, c.scale, c.is_nullable, c.is_identity
          FROM sys.columns c
          JOIN sys.tables t  ON t.object_id = c.object_id
          JOIN sys.schemas s ON s.schema_id = t.schema_id
          JOIN sys.types ty  ON ty.user_type_id = c.user_type_id
         ORDER BY s.name, t.name, c.column_id""")

    pks = {(r[0], r[1], r[2]) for r in query("""
        SELECT s.name, t.name, c.name
          FROM sys.key_constraints kc
          JOIN sys.tables t   ON t.object_id = kc.parent_object_id
          JOIN sys.schemas s  ON s.schema_id = t.schema_id
          JOIN sys.index_columns ic ON ic.object_id = t.object_id AND ic.index_id = kc.unique_index_id
          JOIN sys.columns c  ON c.object_id = t.object_id AND c.column_id = ic.column_id
         WHERE kc.type = 'PK'""")}

    fks = {(r[0], r[1], r[2]): f"{r[3]}.{r[4]}.{r[5]}" for r in query("""
        SELECT sp.name, tp.name, cp.name, sr.name, tr.name, cr.name
          FROM sys.foreign_key_columns fkc
          JOIN sys.tables tp  ON tp.object_id = fkc.parent_object_id
          JOIN sys.schemas sp ON sp.schema_id = tp.schema_id
          JOIN sys.columns cp ON cp.object_id = tp.object_id AND cp.column_id = fkc.parent_column_id
          JOIN sys.tables tr  ON tr.object_id = fkc.referenced_object_id
          JOIN sys.schemas sr ON sr.schema_id = tr.schema_id
          JOIN sys.columns cr ON cr.object_id = tr.object_id AND cr.column_id = fkc.referenced_column_id""")}

    def typ(name: str, ln: int, prec: int, scale: int) -> str:
        if name in ("decimal", "numeric"):
            return f"{name}({prec},{scale})"
        if name in ("nvarchar", "nchar"):
            return f"{name}({'max' if ln == -1 else ln // 2})"
        if name in ("varchar", "char", "binary", "varbinary"):
            return f"{name}({'max' if ln == -1 else ln})"
        return name

    lines: list[str] = [
        "# 資料字典 — CreditRiskDW",
        "",
        "> **本檔由 `etl/gen_data_dictionary.py` 從資料庫系統目錄自動產出，請勿手改。**",
        "> 手寫的資料字典必定過期——欄位改了沒人記得改文件，久了就沒人信。",
        "> 從 `sys.tables` / `sys.columns` 讀取，文件與實際綱要不可能不一致。",
        "",
        f"產出時間：{datetime.now(UTC).strftime('%Y-%m-%d %H:%M UTC')}",
        "",
    ]

    for schema, purpose in SCHEMA_PURPOSE.items():
        st = [t for t in tables if t[0] == schema]
        lines += [f"## `{schema}` — {purpose}", "",
                  f"共 {len(st)} 張表。", ""]
        for _, tname, rows in st:
            lines += [f"### `{schema}.{tname}`　（{rows:,} 列）", "",
                      "| 欄位 | 型別 | 可空 | 鍵 | 參照 |", "|---|---|---|---|---|"]
            for c in columns:
                if c[0] != schema or c[1] != tname:
                    continue
                col = c[3]
                key = "PK" if (schema, tname, col) in pks else ""
                ref = fks.get((schema, tname, col), "")
                if ref and not key:
                    key = "FK"
                ident = " (identity)" if c[9] else ""
                lines.append(
                    f"| `{col}` | {typ(c[4], c[5], c[6], c[7])}{ident} | "
                    f"{'是' if c[8] else '否'} | {key} | {('`' + ref + '`') if ref else ''} |")
            lines.append("")

    # 碼值對照：把維度表的實際內容也寫進字典，這才是使用者真正需要的部分
    lines += ["## 碼值對照", ""]
    for title, sql in [
        ("繳款狀態 `dw.dim_payment_status`",
         "SELECT pay_status_code, ISNULL(documented_desc, N'（文件未定義）'), common_reading"
         " FROM dw.dim_payment_status ORDER BY pay_status_code"),
        ("教育程度 `dw.dim_education`",
         "SELECT education_code, education_desc, CASE WHEN is_documented=1 THEN N'是' ELSE N'否' END"
         " FROM dw.dim_education ORDER BY education_key"),
        ("婚姻狀況 `dw.dim_marriage`",
         "SELECT marriage_code, marriage_desc, CASE WHEN is_documented=1 THEN N'是' ELSE N'否' END"
         " FROM dw.dim_marriage ORDER BY marriage_key"),
    ]:
        hdr = ("| 碼值 | 官方文件定義 | 通行解讀 |" if "payment" in sql
               else "| 碼值 | 說明 | 文件有定義 |")
        lines += [f"### {title}", "", hdr, "|---|---|---|"]
        for code, a, b in query(sql):
            lines.append(f"| `{code}` | {a} | {b} |")
        lines.append("")

    lines += [
        "## 已知的來源資料缺口",
        "",
        "以下不是倉儲的錯誤，是**來源資料與其官方文件不符**，如實記錄以免下游誤用：",
        "",
        "- `EDUCATION` 官方文件只定義 1–4，實際資料出現 0、5、6",
        "- `MARRIAGE` 官方文件只定義 1–3，實際資料出現 0",
        "- `PAY_*` 官方文件只定義 −1 與 1–9，實際資料大量出現 −2 與 0；"
        "學界通行解讀為「當期無消費」與「使用循環信用」，但**那是推論不是文件**，"
        "故維度表把兩者分欄存放",
        "",
    ]

    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"→ {OUT}（{len(tables)} 表、{len(columns)} 欄）")


if __name__ == "__main__":
    main()
