#!/usr/bin/env python3
"""
物件 JSON に通勤時間（ドアtoドア概算）を付与する enricher。

commute.py の駅名ルックアップを使い、各物件について最適な通勤ルートを計算する:
  ドアtoドア = 物件→最寄駅（徒歩） + 最寄駅→オフィス最寄駅（電車） + オフィス最寄駅→オフィス（徒歩）

複数駅が利用できる場合は、目的地ごとに最短となる駅を自動選択する。

※ Google Maps Directions API の transit モードは日本未対応のため、
  commute_playground.json / commute_m3career.json（実測ベースの電車時間テーブル）を使用。

使い方:
  python3 commute_enricher.py --input results/latest.json --output results/latest.json
"""

import argparse
import json
import math
import re
import sys
from datetime import datetime, timezone
from typing import Optional, Dict, Any, Tuple, List

from commute import (
    get_commute_minutes,
    parse_station_walk_pairs,
    ESTIMATE_STATION_TO_OFFICE_M3_MIN,
    ESTIMATE_OFFICE_STATION_WALK_M3_MIN,
    ESTIMATE_STATION_TO_OFFICE_PG_MIN,
    ESTIMATE_OFFICE_STATION_WALK_PG_MIN,
    WALK_CORRECTION_FACTOR,
)


# ---------------------------------------------------------------------------
# 目的地定義
# ---------------------------------------------------------------------------
DESTINATIONS: Dict[str, Dict[str, Any]] = {
    "playground": {
        "name": "Playground",
        "estimate_station_min": ESTIMATE_STATION_TO_OFFICE_PG_MIN,
        "estimate_office_walk": ESTIMATE_OFFICE_STATION_WALK_PG_MIN,
    },
    "m3career": {
        "name": "エムスリーキャリア",
        "estimate_station_min": ESTIMATE_STATION_TO_OFFICE_M3_MIN,
        "estimate_office_walk": ESTIMATE_OFFICE_STATION_WALK_M3_MIN,
    },
}


# ---------------------------------------------------------------------------
# station_line 正規化（新築の「路線名/駅名 徒歩X分」形式を中古の「路線名「駅名」徒歩X分」に統一）
# ---------------------------------------------------------------------------

def _normalize_station_line(station_line: str) -> str:
    """
    新築の station_line 形式を中古と同じ形式に変換する。
      新築: "都営大江戸線/麻布十番 徒歩2分" or "ＪＲ山手線/日暮里 徒歩6分"
      中古: "都営大江戸線「麻布十番」徒歩2分" or "ＪＲ山手線「日暮里」徒歩6分"
    「」で囲まれた駅名がない場合のみ変換する。
    """
    if not station_line:
        return station_line
    # 既に「」形式ならそのまま返す
    if "「" in station_line:
        return station_line
    # "路線名/駅名 徒歩X分" パターンを検出して変換
    # 複数路線は ／ で区切られている場合もある
    segments = re.split(r"[／]", station_line)
    converted = []
    for seg in segments:
        seg = seg.strip()
        if not seg:
            continue
        # "路線名/駅名 徒歩X分" or "路線名/駅名"
        m = re.match(r"^([^/]+)/\s*(.+)$", seg)
        if m:
            line_name = m.group(1).strip()
            rest = m.group(2).strip()
            # rest から駅名を抽出（"駅名 徒歩X分" or "駅名"）
            walk_m = re.search(r"\s+(徒歩\s*約?\s*\d+\s*分.*)$", rest)
            if walk_m:
                station_name = rest[: walk_m.start()].strip()
                walk_part = walk_m.group(1).strip()
                converted.append(f"{line_name}「{station_name}」{walk_part}")
            else:
                converted.append(f"{line_name}「{rest}」")
        else:
            converted.append(seg)
    return "／".join(converted)


# ---------------------------------------------------------------------------
# ドアtoドア通勤時間計算
# ---------------------------------------------------------------------------


def _find_best_route(
    station_walk_pairs: List[Tuple[str, Optional[int]]],
    dest_key: str,
) -> Optional[Dict[str, Any]]:
    """
    複数の駅・徒歩候補から、指定目的地に対して最短のドアtoドア通勤時間を返す。

    Returns:
        {
            "minutes": int,       # ドアtoドア合計（分）
            "station": str,       # 利用駅名
            "walk_min": int,      # 物件→駅の徒歩（分）
            "train_min": int,     # 駅→オフィスの電車+徒歩（分）
            "is_registered": bool # 駅がルックアップに登録されているか
        }
    """
    dest = DESTINATIONS[dest_key]
    best: Optional[Dict[str, Any]] = None

    for station_name, walk_val in station_walk_pairs:
        raw_walk = walk_val if walk_val is not None else 0
        walk = math.ceil(raw_walk * WALK_CORRECTION_FACTOR)
        train_min = get_commute_minutes(station_name, dest_key)
        is_registered = train_min is not None

        if train_min is None:
            # 未登録駅: デフォルト概算（最寄駅→オフィス最寄駅 + オフィス最寄駅→オフィス徒歩）
            train_min = dest["estimate_station_min"] + dest["estimate_office_walk"]

        total = walk + train_min

        if best is None or total < best["minutes"]:
            best = {
                "minutes": total,
                "station": station_name,
                "walk_min": walk,
                "train_min": train_min,
                "is_registered": is_registered,
            }

    return best


def _build_summary(route: Dict[str, Any]) -> str:
    """ルート情報から表示用サマリーを生成する。"""
    station = route["station"]
    walk = route["walk_min"]
    train = route["train_min"]

    if route["is_registered"]:
        # 登録駅: 具体的な駅名とルートを表示
        return f"徒歩{walk}分 + {station}駅から{train}分"
    else:
        # 未登録駅: 概算であることを明示
        return f"(概算) 徒歩{walk}分 + {station}駅から約{train}分"


def _build_commute_info(
    station_line: str,
    walk_min: Optional[int],
) -> Optional[str]:
    """
    駅ベースのドアtoドア通勤時間 JSON 文字列を生成する。
    iOS の CommuteData / CommuteDestination と互換のフォーマット。
    """
    normalized = _normalize_station_line(station_line)
    pairs = parse_station_walk_pairs(normalized, walk_min)
    if not pairs:
        return None

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    commute_info: Dict[str, Any] = {}

    for dest_key in DESTINATIONS:
        route = _find_best_route(pairs, dest_key)
        if route is None:
            continue

        commute_info[dest_key] = {
            "minutes": route["minutes"],
            "summary": _build_summary(route),
            "calculatedAt": now_iso,
        }

    if not commute_info:
        return None
    return json.dumps(commute_info, ensure_ascii=False)


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------


def enrich_commute(listings: list) -> int:
    """物件リストに commute_info を追加する。既にある場合はスキップ。"""
    enriched_count = 0

    for listing in listings:
        # 既に commute_info がある場合はスキップ
        if listing.get("commute_info"):
            continue

        station_line = listing.get("station_line", "")
        walk_min = listing.get("walk_min")

        info_json = _build_commute_info(station_line, walk_min)
        if info_json:
            listing["commute_info"] = info_json
            enriched_count += 1

    return enriched_count


def main() -> None:
    ap = argparse.ArgumentParser(
        description="物件JSONに通勤時間情報（ドアtoドア概算）を付与"
    )
    ap.add_argument("--input", required=True, help="入力JSONファイル")
    ap.add_argument("--output", required=True, help="出力JSONファイル")
    args = ap.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        listings = json.load(f)

    count = enrich_commute(listings)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)

    print(
        f"通勤時間 enrichment 完了: {count}/{len(listings)} 件に通勤情報を付与",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
