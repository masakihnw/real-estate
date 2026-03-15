#!/usr/bin/env python3
"""
ScrapingConfigMetadata から仕様書の検索条件表を生成・同期する。
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
METADATA_PATH = ROOT / "real-estate-ios" / "RealEstateApp" / "ScrapingConfigMetadata.json"
SPEC_PATH = ROOT / "docs" / "SPECIFICATION.md"
START_MARKER = "<!-- AUTO:SCRAPING_CONDITIONS:START -->"
END_MARKER = "<!-- AUTO:SCRAPING_CONDITIONS:END -->"


def _load_metadata() -> dict[str, Any]:
    return json.loads(METADATA_PATH.read_text(encoding="utf-8"))


def _format_price_man(value: int) -> str:
    if value >= 10000:
        oku = value // 10000
        man = value % 10000
        return f"{oku}億円" if man == 0 else f"{oku}億{man:,}万円"
    return f"{value:,}万円"


def _station_summary(meta: dict[str, Any]) -> str:
    groups = meta.get("stationGroups") or []
    if not groups:
        return "未設定"
    parts = []
    total = 0
    for g in groups:
        stations = g.get("stations") or []
        total += len(stations)
        name = str(g.get("line") or "").split("（")[0]
        parts.append(f"{name}（{len(stations)}駅）")
    return f"{'・'.join(parts)} の計{total}駅"


def generate_conditions_table() -> str:
    meta = _load_metadata()
    defaults = meta["defaults"]
    offset = defaults["builtYearMinOffsetYears"]
    area_max = defaults.get("areaMaxM2")
    area_label = (
        f"{defaults['areaMinM2']}㎡以上（上限なし）"
        if area_max is None
        else f"{defaults['areaMinM2']}〜{area_max}㎡"
    )
    price_label = f"{_format_price_man(defaults['priceMinMan'])}〜{_format_price_man(defaults['priceMaxMan'])}"
    station_label = _station_summary(meta)
    layout_label = " / ".join(f"{x}LDK系" for x in defaults["layoutPrefixOk"])
    layout_prefixes = ", ".join(f"\"{x}\"" for x in defaults["layoutPrefixOk"])

    lines = [
        START_MARKER,
        "| 条件 | 値 | 根拠 |",
        "|------|-----|------|",
        "| **エリア** | 東京23区 | — |",
        f"| **対象駅** | {station_label} | 対象エリアの限定 |",
        f"| **価格** | {price_label} | 住み替え前提の投資判断 |",
        f"| **面積** | {area_label} | 需要の厚いゾーン |",
        f"| **間取り** | {layout_label}（プレフィックス {layout_prefixes}） | 買い手母集団が厚い |",
        f"| **築年** | 実行年 − {offset}年以降 | 新耐震 + 築浅優先 |",
        f"| **駅徒歩** | {defaults['walkMinMax']}分以内 | — |",
        f"| **総戸数** | {defaults['totalUnitsMin']}戸以上 | 管理安定性・流動性 |",
        "| **リクエスト間隔** | SUUMO: 2秒 | 負荷軽減 |",
        "| **タイムアウト** | 60秒 / リトライ3回 | 安定性確保 |",
        "| **リトライ戦略（Phase3強化）** | 指数バックオフ（2→4→8→…最大30秒）を HTTP 5xx・接続/読取タイムアウトに適用。429 は `Retry-After` ヘッダー尊重（最大120秒） | ネットワーク耐性 |",
        "| **HOME'S** | **無効**（コード残存、定期実行では未使用） | WAF によりCI/CDパイプラインがタイムアウトするため無効化 |",
        END_MARKER,
    ]
    return "\n".join(lines)


def update_spec_file() -> bool:
    content = SPEC_PATH.read_text(encoding="utf-8")
    table = generate_conditions_table()
    if START_MARKER in content and END_MARKER in content:
        start = content.index(START_MARKER)
        end = content.index(END_MARKER) + len(END_MARKER)
        updated = content[:start] + table + content[end:]
    else:
        anchor = "### 9.1 スクレイピング検索条件（config.py）"
        idx = content.find(anchor)
        if idx < 0:
            raise RuntimeError("SPECIFICATION.md に 9.1 セクションが見つかりません")
        insert_at = content.find("\n", idx)
        updated = content[:insert_at + 1] + "\n" + table + "\n" + content[insert_at + 1:]
    if updated == content:
        return False
    SPEC_PATH.write_text(updated, encoding="utf-8")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description="スクレイピング条件表をメタデータから生成")
    parser.add_argument("--write-spec", action="store_true", help="docs/SPECIFICATION.md の該当ブロックを更新")
    args = parser.parse_args()

    if args.write_spec:
        changed = update_spec_file()
        print("updated" if changed else "no-change")
    else:
        print(generate_conditions_table())


if __name__ == "__main__":
    main()
