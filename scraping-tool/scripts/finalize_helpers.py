#!/usr/bin/env python3
"""
run_finalize.sh で使う後処理ヘルパー。

目的:
- シェル内の長い python -c を排除し、保守性とテスト容易性を上げる
- finalize の主要処理（is_new 注入 / 投資スコア系注入 / 新着件数集計）を責務分離
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from logger import get_logger
logger = get_logger(__name__)

from investment_enricher import enrich_investment_scores
from report_utils import (
    inject_competing_count,
    inject_first_seen_at,
    inject_is_new,
    inject_price_history,
    load_json,
)


def _paths(output_dir: Path) -> dict[str, Path]:
    return {
        "latest": output_dir / "latest.json",
        "previous": output_dir / "previous.json",
        "latest_shinchiku": output_dir / "latest_shinchiku.json",
        "previous_shinchiku": output_dir / "previous_shinchiku.json",
        "transactions": output_dir / "transactions.json",
    }


def inject_new_flags(output_dir: Path) -> None:
    p = _paths(output_dir)

    cur = load_json(p["latest"])
    prev = load_json(p["previous"], missing_ok=True, default=[])
    inject_is_new(cur, prev or None)
    p["latest"].write_text(json.dumps(cur, ensure_ascii=False), encoding="utf-8")

    cur_s = load_json(p["latest_shinchiku"], missing_ok=True, default=[])
    prev_s = load_json(p["previous_shinchiku"], missing_ok=True, default=[])
    if cur_s:
        inject_is_new(cur_s, prev_s or None)
        p["latest_shinchiku"].write_text(json.dumps(cur_s, ensure_ascii=False), encoding="utf-8")

    new_c = sum(1 for r in cur if r.get("is_new"))
    new_s = sum(1 for r in cur_s if r.get("is_new"))
    logger.info(f"is_new 注入完了: 中古 {new_c}/{len(cur)}件, 新築 {new_s}/{len(cur_s)}件")


def _build_tx_ward_counts(path: Path) -> dict[str, dict[str, int]] | None:
    if not path.exists():
        return None
    tx_json = json.loads(path.read_text(encoding="utf-8"))
    tx_data: dict[str, dict[str, int]] = {}
    for bg in tx_json.get("building_groups", []):
        ward = (bg.get("ward", "") or "").replace("区", "")
        if ward not in tx_data:
            tx_data[ward] = {"transaction_count": 0}
        tx_data[ward]["transaction_count"] += bg.get("transaction_count", 0)
    return tx_data


def inject_investment_fields(output_dir: Path) -> None:
    p = _paths(output_dir)
    history_path = str(ROOT / "data" / "first_seen_at.json")

    cur = load_json(p["latest"])
    prev = load_json(p["previous"], missing_ok=True, default=[])
    inject_price_history(cur, prev or None)
    inject_first_seen_at(cur, prev or None, history_path=history_path)
    inject_competing_count(cur)

    tx_data = _build_tx_ward_counts(p["transactions"])
    enrich_investment_scores(cur, tx_data)
    p["latest"].write_text(json.dumps(cur, ensure_ascii=False), encoding="utf-8")

    scored = sum(1 for r in cur if r.get("listing_score") is not None)
    history = sum(1 for r in cur if len(r.get("price_history", [])) > 1)
    logger.info(f"中古: スコア {scored}/{len(cur)}件, 価格変動あり {history}件")

    cur_s = load_json(p["latest_shinchiku"], missing_ok=True, default=[])
    prev_s = load_json(p["previous_shinchiku"], missing_ok=True, default=[])
    if cur_s:
        inject_price_history(cur_s, prev_s or None)
        inject_first_seen_at(cur_s, prev_s or None, history_path=history_path)
        inject_competing_count(cur_s)
        enrich_investment_scores(cur_s, tx_data)
        p["latest_shinchiku"].write_text(json.dumps(cur_s, ensure_ascii=False), encoding="utf-8")
        scored_s = sum(1 for r in cur_s if r.get("listing_score") is not None)
        logger.info(f"新築: スコア {scored_s}/{len(cur_s)}件")


def count_new(output_dir: Path) -> None:
    p = _paths(output_dir)

    latest = load_json(p["latest"], missing_ok=True, default=[])
    new_items = [r for r in latest if r.get("is_new")]
    new_chuko = len(new_items)
    new_building = sum(1 for r in new_items if r.get("is_new_building"))
    new_room = new_chuko - new_building

    latest_s = load_json(p["latest_shinchiku"], missing_ok=True, default=[])
    new_shinchiku = sum(1 for r in latest_s if r.get("is_new"))

    # run_finalize.sh から read しやすいように4値を1行で出力
    print(f"{new_chuko} {new_building} {new_room} {new_shinchiku}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Finalize 処理の Python ヘルパー")
    parser.add_argument("command", choices=["inject-new", "inject-investment", "count-new"])
    parser.add_argument("--output-dir", default="results", help="results ディレクトリのパス")
    args = parser.parse_args()

    output_dir = (ROOT / args.output_dir).resolve()
    if args.command == "inject-new":
        inject_new_flags(output_dir)
    elif args.command == "inject-investment":
        inject_investment_fields(output_dir)
    else:
        count_new(output_dir)


if __name__ == "__main__":
    main()
