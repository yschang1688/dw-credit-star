#!/usr/bin/env python3
"""從 dbt manifest.json 產出資料血緣文件（docs/lineage.md）。

血緣圖是推導出來的，不是畫出來的：來源＝ `ref()`／`source()` 依賴 ＋ exposures 宣告。
手畫的血緣圖在第二次改模型時就過期，而且沒有人會發現——這支腳本的 `--check` 模式
放進 CI，文件與程式碼一漂移就紅燈。

用法：
    python tools/lineage_md.py            # 重新產出 docs/lineage.md
    python tools/lineage_md.py --check    # 只比對，不一致則 exit 1（CI 用）

前置：先在 dbt/ 跑過 `dbt parse`（或任何會寫 target/manifest.json 的指令）。
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "dbt" / "target" / "manifest.json"
OUT = ROOT / "docs" / "lineage.md"

LAYER_ORDER = ["source", "seed", "staging", "utilities", "marts", "semantic", "exposure"]
LAYER_LABEL = {
    "source": "來源落地層（stg，由 T-SQL ETL 寫入）",
    "seed": "參考維度 seeds",
    "staging": "暫存層（view，不做業務轉換）",
    "utilities": "工具模型",
    "marts": "維度／事實層",
    "semantic": "語意層（指標唯一定義）",
    "exposure": "下游消費者",
}


def layer_of(node: dict) -> str:
    kind = node["resource_type"]
    if kind == "source":
        return "source"
    if kind == "seed":
        return "seed"
    if kind == "exposure":
        return "exposure"
    if kind in ("semantic_model", "metric"):
        return "semantic"
    fqn = node.get("fqn", [])
    for layer in ("staging", "marts", "utilities"):
        if layer in fqn:
            return layer
    return "marts"


def short(unique_id: str) -> str:
    return unique_id.split(".")[-1]


def node_id(unique_id: str) -> str:
    return unique_id.replace(".", "_").replace("-", "_")


def build(manifest: dict) -> str:
    nodes: dict[str, dict] = {}
    for coll in ("nodes", "sources", "exposures", "semantic_models", "metrics"):
        for uid, n in manifest.get(coll, {}).items():
            if n["resource_type"] in ("model", "seed", "source", "exposure", "semantic_model", "metric"):
                nodes[uid] = n

    edges: list[tuple[str, str]] = []
    for uid, n in nodes.items():
        for dep in n.get("depends_on", {}).get("nodes", []):
            if dep in nodes:
                edges.append((dep, uid))
        # metric → semantic_model 的依賴在 depends_on 裡；ratio metric 依賴其他 metric
    edges = sorted(set(edges))

    by_layer: dict[str, list[str]] = defaultdict(list)
    for uid, n in nodes.items():
        by_layer[layer_of(n)].append(uid)

    lines = [
        "# 資料血緣",
        "",
        "> 本檔由 `tools/lineage_md.py` 從 `dbt/target/manifest.json` 產出，**請勿手改**；",
        "> CI 以 `--check` 比對，模型或 exposure 一改、文件沒重產就紅燈。",
        "> 血緣的來源是 `ref()`／`source()` 依賴與 `exposures.yml` 宣告——推導出來的，不是畫出來的。",
        "",
        "## 血緣圖",
        "",
        "```mermaid",
        "flowchart LR",
    ]
    for layer in LAYER_ORDER:
        ids = sorted(by_layer.get(layer, []), key=short)
        if not ids:
            continue
        lines.append(f'  subgraph {layer}["{LAYER_LABEL[layer]}"]')
        for uid in ids:
            n = nodes[uid]
            label = short(uid)
            if n["resource_type"] == "metric":
                label = f"📐 {label}"
            elif n["resource_type"] == "exposure":
                label = f"📊 {n.get('label') or label}"
            lines.append(f'    {node_id(uid)}["{label}"]')
        lines.append("  end")
    for a, b in edges:
        lines.append(f"  {node_id(a)} --> {node_id(b)}")
    lines += ["```", ""]

    # 逐節點依賴表：變更影響分析用（改了 X，往下會動到誰）
    downstream: dict[str, list[str]] = defaultdict(list)
    for a, b in edges:
        downstream[a].append(b)
    lines += [
        "## 變更影響（改了左邊，右邊會受影響）",
        "",
        "| 節點 | 層 | 直接下游 |",
        "|---|---|---|",
    ]
    for layer in LAYER_ORDER:
        for uid in sorted(by_layer.get(layer, []), key=short):
            ds = ", ".join(sorted(short(d) for d in downstream.get(uid, []))) or "—"
            lines.append(f"| `{short(uid)}` | {layer} | {ds} |")
    lines.append("")

    # 指標 → 定義摘要
    metrics = [nodes[u] for u in by_layer.get("semantic", []) if nodes[u]["resource_type"] == "metric"]
    ratio = [m for m in metrics if m.get("type") == "ratio"]
    if ratio:
        lines += ["## 業務指標的唯一定義（`dbt/models/marts/_semantic.yml`）", "",
                  "| 指標 | 分子 | 分母 |", "|---|---|---|"]
        for m in sorted(ratio, key=lambda m: m["name"]):
            tp = m.get("type_params", {})
            num = tp.get("numerator", {}); den = tp.get("denominator", {})
            num = num.get("name") if isinstance(num, dict) else num
            den = den.get("name") if isinstance(den, dict) else den
            lines.append(f"| {m.get('label') or m['name']} (`{m['name']}`) | `{num}` | `{den}` |")
        lines.append("")
    return "\n".join(lines) + "\n"


def main() -> int:
    if not MANIFEST.exists():
        sys.exit(f"找不到 {MANIFEST}——先在 dbt/ 跑 `dbt parse`")
    text = build(json.loads(MANIFEST.read_text()))
    if "--check" in sys.argv:
        current = OUT.read_text() if OUT.exists() else ""
        if current != text:
            print(f"✗ {OUT.relative_to(ROOT)} 與 manifest 不一致——跑 `python tools/lineage_md.py` 重產後提交")
            return 1
        print(f"✓ {OUT.relative_to(ROOT)} 與 manifest 一致")
        return 0
    OUT.write_text(text)
    print(f"已寫入 {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
