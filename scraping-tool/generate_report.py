#!/usr/bin/env python3
"""
スクレイピング結果を Markdown 形式の見やすいレポートに変換。
前回結果との差分（新規・価格変動・削除）を検出して表示。
検索条件（config.py）をレポートに含める。

使い方:
  python generate_report.py result.json -o report.md
  python generate_report.py result.json --compare previous.json -o report.md
"""

import argparse
import sys
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from pathlib import Path

JST = timezone(timedelta(hours=9))
from typing import Any, Optional

from optional_features import optional_features
from report_utils import (
    compare_listings,
    format_address_from_ward,
    format_area,
    format_floor,
    format_price,
    format_walk,
    get_station_group,
    get_ward_from_address,
    google_maps_link,
    load_json,
    listing_key,
    normalize_listing_name,
    row_merge_key,
    format_total_units,
)

try:
    from config import (
        PRICE_MIN_MAN,
        PRICE_MAX_MAN,
        AREA_MIN_M2,
        AREA_MAX_M2,
        BUILT_YEAR_MIN,
        WALK_MIN_MAX,
        TOTAL_UNITS_MIN,
        STATION_PASSENGERS_MIN,
        AREA_LABEL,
        TOKYO_23_WARDS,
        ALLOWED_LINE_KEYWORDS,
    )
except ImportError:
    PRICE_MIN_MAN, PRICE_MAX_MAN = 7500, 10000
    AREA_MIN_M2, AREA_MAX_M2 = 65, 70
    BUILT_YEAR_MIN = datetime.now().year - 20
    WALK_MIN_MAX = 7
    TOTAL_UNITS_MIN = 100
    STATION_PASSENGERS_MIN = 0
    AREA_LABEL = "東京23区"
    ALLOWED_LINE_KEYWORDS = ()
    TOKYO_23_WARDS = (
        "千代田区", "中央区", "港区", "新宿区", "文京区", "台東区", "墨田区", "江東区",
        "品川区", "目黒区", "大田区", "世田谷区", "渋谷区", "中野区", "杉並区", "豊島区",
        "北区", "荒川区", "板橋区", "練馬区", "足立区", "葛飾区", "江戸川区",
    )


def get_search_conditions_md() -> str:
    """検索条件（config.py）をMarkdownの表形式で全て列挙。"""
    if PRICE_MAX_MAN >= 10000:
        price_range = f"{PRICE_MIN_MAN // 10000}億{PRICE_MIN_MAN % 10000}万〜{PRICE_MAX_MAN // 10000}億円" if PRICE_MIN_MAN >= 10000 else f"{PRICE_MIN_MAN:,}万〜{PRICE_MAX_MAN // 10000}億円"
    else:
        price_range = f"{PRICE_MIN_MAN:,}万〜{PRICE_MAX_MAN:,}万円"
    rows = [
        "| 項目 | 条件 |",
        "|------|------|",
        f"| 検索地域 | {AREA_LABEL} |",
        f"| 価格 | {price_range} |",
        f"| 専有面積 | {AREA_MIN_M2}〜{AREA_MAX_M2}㎡ |",
        "| 間取り | 2LDK〜3LDK 系（2LDK, 3LDK, 2DK, 3DK など） |",
        f"| 築年 | {BUILT_YEAR_MIN}年以降（築20年以内） |",
        f"| 駅徒歩 | {WALK_MIN_MAX}分以内 |",
        f"| 総戸数 | {TOTAL_UNITS_MIN}戸以上 |",
        "| 資産性ランク | 独自スコア（駅乗降客数・徒歩・築年・総戸数）4段階（S/A/B/C）。参考値。 |",
        "| 表示対象 | 資産性B以上（S/A/B）の物件のみ表示。根拠は表の「資産性根拠」列参照。 |",
        "| 10年シミュレーション | FutureEstatePredictor（収益還元・原価法ハイブリッド）による楽観・中立・悲観3シナリオ。各列に「予測金額（含み益/騰落率）」を表示。 |",
        "| ローン試算 | 50年変動金利・頭金なし。諸経費（修繕積立等）月3.5万円を加算した月額支払。 |",
        "| 通勤時間 | エムスリーキャリア（虎ノ門）・playground（千代田区一番町）まで。ドアtoドア（物件→最寄駅の徒歩＋最寄駅→オフィス）。登録済み駅はその合計、未登録は(概算)で徒歩＋駅→会社最寄り駅＋会社最寄り駅→会社の徒歩を表示。 |",
    ]
    if ALLOWED_LINE_KEYWORDS:
        line_label = "・".join(ALLOWED_LINE_KEYWORDS[:5]) + (" など" if len(ALLOWED_LINE_KEYWORDS) > 5 else "")
        rows.append(f"| 路線 | {line_label} に限定 |")
    if STATION_PASSENGERS_MIN > 0:
        rows.append(f"| 駅乗降客数 | 1日あたり {STATION_PASSENGERS_MIN:,}人以上の駅のみ（data/station_passengers.json） |")
    return "\n".join(rows)


def _is_asset_rank_b_or_above(r: dict) -> bool:
    """資産性がB以上（S/A/B）かどうか。"""
    _, rank = optional_features.get_asset_score_and_rank(r)
    return rank in ("S", "A", "B")


def _price_diff_for_sort(r: dict) -> float:
    """現在価格と10年後推定価格の差額（万円）。差額が大きい順ソート用。"""
    price_man = r.get("price_man") or 0
    sim = optional_features.simulate_10year_from_listing(r)
    price_10y = getattr(sim, "price_10y_man", 0) or 0 if sim else 0
    return price_man - price_10y


def _listing_cells(r: dict) -> dict[str, Any]:
    """1物件の表用セル値をまとめて返す。行組み立ての重複を避ける。"""
    _, rank, breakdown = optional_features.get_asset_score_and_rank_with_breakdown(r)
    opt_10y, neu_10y, pes_10y = optional_features.get_three_scenario_columns(r)
    monthly_loan, _ = optional_features.get_loan_display_for_listing(r.get("price_man"))
    m3_str, pg_str = optional_features.get_commute_display_with_estimate(r.get("station_line"), r.get("walk_min"))
    return {
        "rank": rank,
        "breakdown": breakdown,
        "opt_10y": opt_10y,
        "neu_10y": neu_10y,
        "pes_10y": pes_10y,
        "monthly_loan": monthly_loan,
        "m3_str": m3_str,
        "pg_str": pg_str,
        "name": (r.get("name") or "")[:30],
        "price": format_price(r.get("price_man")),
        "layout": r.get("layout", "-"),
        "area": format_area(r.get("area_m2")),
        "built": f"築{r.get('built_year', '-')}年" if r.get("built_year") else "-",
        "walk": optional_features.format_all_station_walk(r.get("station_line"), r.get("walk_min")),
        "floor_str": format_floor(r.get("floor_position"), r.get("floor_total")),
        "units": format_total_units(r.get("total_units")),
        "address_short": format_address_from_ward(r.get("address") or ""),
        "address_trunc": (r.get("address") or "")[:20],
        "gmap": google_maps_link(r.get("address") or ""),
    }


def _link_from_group(group: list[dict]) -> str:
    """同名・同価格・同間取りのグループから詳細リンク文字列を組み立てる。"""
    urls = [x.get("url", "") for x in group if x.get("url")]
    if len(urls) == 1:
        return f"[詳細]({urls[0]})"
    link = " ".join(f"[{i+1}]({u})" for i, u in enumerate(urls[:3]))
    if len(urls) > 3:
        link += f" 他{len(urls)-3}件"
    return link


def generate_markdown(
    listings: list[dict[str, Any]],
    diff: Optional[dict[str, Any]] = None,
    output_path: Optional[Path] = None,
    report_url: Optional[str] = None,
) -> str:
    """Markdown形式のレポートを生成。資産性B以上の物件のみ表示し、根拠列を追加。"""
    now = datetime.now(JST).strftime("%Y年%m月%d日 %H:%M")
    search_conditions = get_search_conditions_md()

    # 資産性B以上に絞る
    listings_a = [r for r in listings if _is_asset_rank_b_or_above(r)]
    diff_a: Optional[dict[str, Any]] = None
    if diff:
        diff_a = {
            "new": [r for r in diff.get("new", []) if _is_asset_rank_b_or_above(r)],
            "updated": [item for item in diff.get("updated", []) if _is_asset_rank_b_or_above(item.get("current", {}))],
            "removed": [r for r in diff.get("removed", []) if _is_asset_rank_b_or_above(r)],
        }

    lines = [
        "# 中古マンション物件一覧レポート",
        "",
    ]
    if report_url and report_url.strip():
        lines.extend([
            f"**レポート（GitHub）**: [results/report を開く]({report_url.strip()})",
            "",
        ])
    lines.extend([
        "## 🔍 検索条件（一覧）",
        "",
        "このレポートは以下の条件で検索・取得した物件です。**資産性B以上のみ表示**。",
        "",
        search_conditions,
        "",
        "---",
        "",
        f"**更新日時**: {now}（JST）",
        f"**対象件数**: {len(listings_a)}件（資産性B以上 / 全{len(listings)}件中）",
        "",
    ])

    # 新規物件（区に関係なく一番上に表示。同名・同価格・同間取りは1行にまとめる）
    if diff_a and diff_a["new"]:
        m3_label, pg_label = optional_features.get_destination_labels()
        lines.extend([
            "## 🆕 新規物件",
            "",
            f"| 物件名 | 価格 | 間取り | 専有 | 築年 | 駅徒歩 | 階 | 総戸数 | 資産性(S/A/B/C) | 資産性根拠 | 楽観10年後 | 中立10年後 | 悲観10年後 | 月額(50年・諸経費3.5万) | {m3_label} | {pg_label} | 所在地 | Google Map | 詳細 |",
            f"|--------|------|--------|------|------|--------|-----|--------|----------------|------------|------------|------------|------------|------------------------|------|------|--------|------------|------|",
        ])
        new_groups: dict[tuple, list[dict]] = defaultdict(list)
        for r in diff_a["new"]:
            new_groups[row_merge_key(r)].append(r)
        for group in sorted(new_groups.values(), key=lambda g: _price_diff_for_sort(g[0]), reverse=True):
            r = group[0]
            c = _listing_cells(r)
            link = _link_from_group(group)
            lines.append(f"| {c['name']} | {c['price']} | {c['layout']} | {c['area']} | {c['built']} | {c['walk']} | {c['floor_str']} | {c['units']} | {c['rank']} | {c['breakdown']} | {c['opt_10y']} | {c['neu_10y']} | {c['pes_10y']} | {c['monthly_loan']} | {c['m3_str']} | {c['pg_str']} | {c['address_trunc']} | {c['gmap']} | {link} |")
        lines.append("")

    # 変更サマリー（新規・価格変動・削除の件数）
    if diff_a:
        new_count = len(diff_a["new"])
        updated_count = len(diff_a["updated"])
        removed_count = len(diff_a["removed"])
        if new_count > 0 or updated_count > 0 or removed_count > 0:
            lines.extend([
                "## 📊 変更サマリー",
                "",
                f"- 🆕 **新規**: {new_count}件",
                f"- 🔄 **価格変動**: {updated_count}件",
                f"- ❌ **削除**: {removed_count}件",
                "",
            ])

    # 価格変動
    if diff_a and diff_a["updated"]:
        m3_label, pg_label = optional_features.get_destination_labels()
        lines.extend([
            "## 🔄 価格変動",
            "",
            f"| 物件名 | 変更前 | 変更後 | 差額 | 間取り | 専有 | 階 | 総戸数 | 資産性(S/A/B/C) | 資産性根拠 | 楽観10年後 | 中立10年後 | 悲観10年後 | 月額(50年・諸経費3.5万) | {m3_label} | {pg_label} | Google Map | 詳細URL |",
            f"|--------|--------|--------|------|--------|------|-----|--------|----------------|------------|------------|------------|------------|------------------------|------|------|------------|---------|",
        ])
        for item in sorted(diff_a["updated"], key=lambda x: _price_diff_for_sort(x["current"]), reverse=True):
            curr = item["current"]
            prev = item["previous"]
            c = _listing_cells(curr)
            prev_price = format_price(prev.get("price_man"))
            curr_price = c["price"]
            diff_price = (curr.get("price_man") or 0) - (prev.get("price_man") or 0)
            diff_str = f"{'+' if diff_price >= 0 else ''}{diff_price}万円" if diff_price != 0 else "変動なし"
            url = curr.get("url", "")
            lines.append(f"| {c['name']} | {prev_price} | {curr_price} | {diff_str} | {c['layout']} | {c['area']} | {c['floor_str']} | {c['units']} | {c['rank']} | {c['breakdown']} | {c['opt_10y']} | {c['neu_10y']} | {c['pes_10y']} | {c['monthly_loan']} | {c['m3_str']} | {c['pg_str']} | {c['gmap']} | [詳細]({url}) |")
        lines.append("")

    # 削除された物件
    if diff_a and diff_a["removed"]:
        m3_label, pg_label = optional_features.get_destination_labels()
        lines.extend([
            "## ❌ 削除された物件",
            "",
            f"| 物件名 | 価格 | 間取り | 専有 | 階 | 総戸数 | 資産性(S/A/B/C) | 資産性根拠 | 楽観10年後 | 中立10年後 | 悲観10年後 | 月額(50年・諸経費3.5万) | {m3_label} | {pg_label} | Google Map | 詳細URL |",
            f"|--------|------|--------|------|-----|--------|----------------|------------|------------|------------|------------|------------------------|------|------|------------|---------|",
        ])
        for r in sorted(diff_a["removed"], key=_price_diff_for_sort, reverse=True):
            c = _listing_cells(r)
            url = r.get("url", "")
            lines.append(f"| {c['name']} | {c['price']} | {c['layout']} | {c['area']} | {c['floor_str']} | {c['units']} | {c['rank']} | {c['breakdown']} | {c['opt_10y']} | {c['neu_10y']} | {c['pes_10y']} | {c['monthly_loan']} | {c['m3_str']} | {c['pg_str']} | {c['gmap']} | [詳細]({url}) |")
        lines.append("")

    # 全物件一覧: 区ごと → 最寄駅ごとにセクション（資産性B以上の物件のみ）
    lines.append("## 📋 物件一覧（区・最寄駅別・資産性B以上）")
    lines.append("")

    # 区 → 最寄駅 → 物件リストにグループ化（区の順序は TOKYO_23_WARDS）
    ward_order = {w: i for i, w in enumerate(TOKYO_23_WARDS)}
    by_ward: dict[str, list[dict]] = {}
    no_ward: list[dict] = []
    for r in listings_a:
        ward = get_ward_from_address(r.get("address") or "")
        if ward:
            by_ward.setdefault(ward, []).append(r)
        else:
            no_ward.append(r)

    # 区を TOKYO_23_WARDS の順で、その後「その他」
    ordered_wards = sorted(by_ward.keys(), key=lambda w: ward_order.get(w, 999))
    if no_ward:
        ordered_wards.append("(区不明)")
        by_ward["(区不明)"] = no_ward

    for ward in ordered_wards:
        ward_listings = by_ward.get(ward, [])
        if not ward_listings:
            continue
        lines.append(f"### {ward}")
        lines.append("")

        # 最寄駅でグループ化
        by_station: dict[str, list[dict]] = {}
        for r in ward_listings:
            st = get_station_group(r.get("station_line") or "")
            by_station.setdefault(st, []).append(r)

        for station in sorted(by_station.keys()):
            st_listings = by_station[station]
            lines.append(f"#### {station}")
            # その駅グループの所在地（区以降）を重複除いて列挙
            addrs = []
            seen: set[str] = set()
            for r in st_listings:
                a = format_address_from_ward(r.get("address") or "")
                if a != "-" and a not in seen:
                    seen.add(a)
                    addrs.append(a)
            if addrs:
                lines.append("所在地: " + "、".join(addrs[:5]) + (" 他" if len(addrs) > 5 else ""))
            lines.append("")
            m3_label, pg_label = optional_features.get_destination_labels()
            lines.append(f"| 物件名 | 価格 | 間取り | 専有 | 築年 | 駅徒歩 | 所在地 | Google Map | 階 | 総戸数 | 資産性(S/A/B/C) | 資産性根拠 | 楽観10年後 | 中立10年後 | 悲観10年後 | 月額(50年・諸経費3.5万) | {m3_label} | {pg_label} | 詳細 |")
            lines.append("|--------|------|--------|------|------|--------|--------|------------|-----|--------|----------------|------------|------------|------------|------------|------------------------|------|------|------|")

            # 同名・同価格・同間取りで1行にまとめる。現在価格と10年後推定価格の差額が大きい順に表示
            merge_groups: dict[tuple, list[dict]] = defaultdict(list)
            for r in st_listings:
                merge_groups[row_merge_key(r)].append(r)
            for group in sorted(merge_groups.values(), key=lambda g: _price_diff_for_sort(g[0]), reverse=True):
                r = group[0]
                c = _listing_cells(r)
                link = _link_from_group(group)
                lines.append(f"| {c['name']} | {c['price']} | {c['layout']} | {c['area']} | {c['built']} | {c['walk']} | {c['address_short']} | {c['gmap']} | {c['floor_str']} | {c['units']} | {c['rank']} | {c['breakdown']} | {c['opt_10y']} | {c['neu_10y']} | {c['pes_10y']} | {c['monthly_loan']} | {c['m3_str']} | {c['pg_str']} | {link} |")
            lines.append("")

    lines.extend([
        "---",
        "",
        f"*レポート生成日時: {now}（JST）*",
    ])

    content = "\n".join(lines)
    if output_path:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"レポートを生成しました: {output_path}", file=sys.stderr)
    return content


def main() -> None:
    ap = argparse.ArgumentParser(description="スクレイピング結果をMarkdownレポートに変換")
    ap.add_argument("input", type=Path, help="入力JSONファイル（main.pyの出力）")
    ap.add_argument("--compare", "-c", type=Path, help="前回結果JSONファイル（差分検出用）")
    ap.add_argument("--output", "-o", type=Path, help="出力Markdownファイル（未指定時はstdout）")
    ap.add_argument("--report-url", type=str, default=None, help="GitHub の results/report へのURL（指定時のみレポート先頭にリンクを記載）")
    args = ap.parse_args()

    current = load_json(args.input)
    previous = load_json(args.compare) if args.compare and args.compare.exists() else None

    diff = compare_listings(current, previous) if previous else None
    content = generate_markdown(current, diff, args.output, report_url=args.report_url)

    if not args.output:
        print(content)


if __name__ == "__main__":
    main()
