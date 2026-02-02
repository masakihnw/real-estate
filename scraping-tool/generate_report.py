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
import json
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.parse import quote

JST = timezone(timedelta(hours=9))
from typing import Any, Optional

try:
    from asset_score import get_asset_score_and_rank, get_asset_score_and_rank_with_breakdown
except ImportError:
    def get_asset_score_and_rank(r: dict, **kwargs: Any) -> tuple[float, str]:
        return 0.0, "-"

    def get_asset_score_and_rank_with_breakdown(r: dict, **kwargs: Any) -> tuple[float, str, str]:
        return 0.0, "-", "-"

try:
    from asset_simulation import simulate_10year_from_listing, format_simulation_for_report
except ImportError:
    def simulate_10year_from_listing(r: dict) -> Any:
        return None

    def format_simulation_for_report(sim: Any) -> tuple[str, str, str, str]:
        return "-", "-", "-", "-"

try:
    from loan_calc import get_loan_display_for_listing
except ImportError:
    def get_loan_display_for_listing(price_man: Optional[float]) -> tuple[str, str]:
        return "-", "-"

try:
    from commute import get_commute_display_with_estimate, get_destination_labels, format_all_station_walk
except ImportError:
    def get_commute_display_with_estimate(station_line: str, walk_min: Optional[int]) -> tuple[str, str]:
        return ("-", "-")

    def get_destination_labels() -> tuple[str, str]:
        return ("エムスリーキャリア", "playground(一番町)")

    def format_all_station_walk(station_line: str, fallback_walk_min: Optional[int]) -> str:
        return format_walk(fallback_walk_min) if fallback_walk_min is not None else "-"

try:
    from price_predictor import (
        MansionPricePredictor,
        listing_to_property_data,
        _calc_loan_residual_10y_yen,
    )
    _PRICE_PREDICTOR: Optional[MansionPricePredictor] = None

    def _get_predictor() -> MansionPricePredictor:
        global _PRICE_PREDICTOR
        if _PRICE_PREDICTOR is None:
            _PRICE_PREDICTOR = MansionPricePredictor()
            _PRICE_PREDICTOR.load_data()
        return _PRICE_PREDICTOR

    def _format_scenario_cell(price_yen: int, contract_yen: int, loan_residual_yen: float) -> str:
        """1シナリオのセル: 予測金額（含み益/騰落率）形式。例: 8204万円（+1000万円/+8.6%）"""
        if price_yen <= 0 or contract_yen <= 0:
            return "-"
        price_man = price_yen / 10000
        implied_yen = price_yen - loan_residual_yen
        implied_man = implied_yen / 10000
        change_pct = (price_yen / contract_yen - 1.0) * 100
        price_str = format_price(int(round(price_man)))
        # 含み益: 1億以上は「1億○○万円」、それ以外は「±○○万円」
        if abs(implied_man) >= 10000:
            oku = int(abs(implied_man) // 10000)
            man = int(round(abs(implied_man) % 10000))
            sign = "+" if implied_man >= 0 else "-"
            implied_str = f"{sign}{oku}億{man}万円" if man else f"{sign}{oku}億円"
        else:
            implied_str = f"{'+' if implied_man >= 0 else ''}{int(round(implied_man))}万円"
        return f"{price_str}（{implied_str}/{change_pct:+.1f}%）"

    def get_three_scenario_columns(listing: dict[str, Any]) -> tuple[str, str, str]:
        """楽観・中立・悲観の3列セルを返す。各セルは「予測金額（含み益/騰落率）」形式。"""
        if not listing.get("price_man") and not listing.get("listing_price"):
            return "-", "-", "-"
        prop = listing_to_property_data(listing)
        if not prop.get("listing_price"):
            return "-", "-", "-"
        try:
            pred = _get_predictor().predict(prop)
            contract = pred.get("current_estimated_contract_price") or 0
            f = pred.get("10y_forecast") or {}
            best_yen = f.get("best") or 0
            std_yen = f.get("standard") or 0
            worst_yen = f.get("worst") or 0
            if contract <= 0:
                return "-", "-", "-"
            loan_residual = _calc_loan_residual_10y_yen(contract)
            opt = _format_scenario_cell(best_yen, contract, loan_residual)
            neu = _format_scenario_cell(std_yen, contract, loan_residual)
            pes = _format_scenario_cell(worst_yen, contract, loan_residual)
            return opt, neu, pes
        except Exception:
            return "-", "-", "-"

    def get_price_predictor_3scenarios(listing: dict[str, Any]) -> str:
        """物件1件について price_predictor の 10年後3シナリオ（Standard/Best/Worst）を取得し、表用文字列で返す。"""
        opt, neu, pes = get_three_scenario_columns(listing)
        if opt == "-" and neu == "-" and pes == "-":
            return "-"
        return f"{neu} / {opt} / {pes}"  # 中立 / 楽観 / 悲観（後方互換用）
except ImportError:
    def get_three_scenario_columns(listing: dict[str, Any]) -> tuple[str, str, str]:
        return "-", "-", "-"

    def get_price_predictor_3scenarios(listing: dict[str, Any]) -> str:
        return "-"

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


def load_json(path: Path) -> list[dict[str, Any]]:
    """JSONファイルを読み込む。"""
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def normalize_listing_name(name: str) -> str:
    """同一判定用に物件名を正規化。全角・半角スペース等を除いて比較する。"""
    if not name:
        return ""
    s = (name or "").strip()
    return re.sub(r"\s+", "", s)


def listing_key(r: dict) -> tuple:
    """同一物件判定用のキー。名前・間取り・広さ・価格・住所・築年・駅徒歩が全て一致すれば同一とする。"""
    return (
        normalize_listing_name(r.get("name") or ""),
        (r.get("layout") or "").strip(),
        r.get("area_m2"),
        r.get("price_man"),
        (r.get("address") or "").strip(),
        r.get("built_year"),
        (r.get("station_line") or "").strip(),
        r.get("walk_min"),
    )


def compare_listings(current: list[dict], previous: Optional[list[dict]] = None) -> dict[str, Any]:
    """前回結果と比較して差分を検出。同一物件は listing_key（名前・条件一致）で判定する。"""
    if not previous:
        return {
            "new": current,
            "updated": [],
            "removed": [],
            "unchanged": [],
        }

    # 物件キー（名前・間取り・広さ・価格・住所・築年・駅徒歩）で辞書化（同一キーは1件目を採用）
    current_by_key: dict[tuple, dict] = {}
    for r in current:
        k = listing_key(r)
        if k not in current_by_key:
            current_by_key[k] = r
    previous_by_key: dict[tuple, dict] = {}
    for r in previous:
        k = listing_key(r)
        if k not in previous_by_key:
            previous_by_key[k] = r

    new = []
    updated = []
    unchanged = []
    removed = []

    for k, curr in current_by_key.items():
        prev = previous_by_key.get(k)
        if not prev:
            new.append(curr)
        elif curr.get("price_man") != prev.get("price_man"):
            updated.append({"current": curr, "previous": prev})
        else:
            unchanged.append(curr)

    for k, prev in previous_by_key.items():
        if k not in current_by_key:
            removed.append(prev)

    return {
        "new": new,
        "updated": updated,
        "removed": removed,
        "unchanged": unchanged,
    }


def format_price(price_man: Optional[int]) -> str:
    """価格を読みやすい形式に。"""
    if price_man is None:
        return "-"
    if price_man >= 10000:
        oku = price_man // 10000
        man = price_man % 10000
        if man == 0:
            return f"{oku}億円"
        return f"{oku}億{man}万円"
    return f"{price_man}万円"


def format_area(area_m2: Optional[float]) -> str:
    """専有面積を読みやすい形式に。"""
    if area_m2 is None:
        return "-"
    return f"{area_m2:.1f}㎡"


def format_walk(walk_min: Optional[int]) -> str:
    """徒歩分数を読みやすい形式に。"""
    if walk_min is None:
        return "-"
    return f"徒歩{walk_min}分"


def format_total_units(total_units: Optional[int]) -> str:
    """総戸数を読みやすい形式に。未取得時は「戸数:不明」（列名が分かるように）。"""
    if total_units is None:
        return "戸数:不明"
    return f"{total_units}戸"


def format_floor(floor_position: Optional[int], floor_total: Optional[int]) -> str:
    """何階 / 何階建て を読みやすい形式に。未取得時は「階:-」（列名が分かるように）。"""
    pos = floor_position is not None and floor_position >= 0
    tot = floor_total is not None and floor_total >= 1
    if pos and tot:
        return f"{floor_position}階/{floor_total}階建"
    if pos:
        return f"{floor_position}階"
    if tot:
        return f"{floor_total}階建"
    return "階:-"


def row_merge_key(r: dict) -> tuple:
    """同一行にまとめるキー: 物件名・価格・間取りが同じなら1行にする。名前は正規化して全角スペース差を無視。"""
    return (
        normalize_listing_name(r.get("name") or ""),
        r.get("price_man"),
        (r.get("layout") or "").strip(),
    )


def get_ward_from_address(address: str) -> str:
    """住所から23区の区名を取得。見つからなければ空文字。"""
    if not address:
        return ""
    for w in TOKYO_23_WARDS:
        if w in address:
            return w
    return ""


def format_address_from_ward(address: str) -> str:
    """住所から「区」以降を返す。例: 東京都目黒区五本木１ → 目黒区五本木１。"""
    if not address or not address.strip():
        return "-"
    s = address.strip()
    # 東京都を除く
    if s.startswith("東京都"):
        s = s[3:].lstrip()
    # 既に区から始まっていればそのまま。区が含まれる場合は区の位置から
    for w in TOKYO_23_WARDS:
        if w in s:
            idx = s.find(w)
            return s[idx:].strip() or "-"
    return s[:30] or "-"


def google_maps_link(address: str) -> str:
    """住所から Google Map のハイパーリンク Markdown を返す。例: [Google Map](https://...)"""
    if not address or not address.strip():
        return "-"
    q = quote(address.strip())
    url = f"https://www.google.com/maps/search/?api=1&query={q}"
    return f"[Google Map]({url})"


def get_station_group(station_line: str) -> str:
    """路線・駅文字列から最寄駅グループ用のラベルを取得。『』内があればそれ、なければ先頭25文字。"""
    if not station_line or not station_line.strip():
        return "(駅情報なし)"
    m = re.search(r"[「『]([^」』]+)[」』]", station_line)
    if m:
        return m.group(1).strip()
    return (station_line.strip()[:25] or "(駅情報なし)")


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
    _, rank = get_asset_score_and_rank(r)
    return rank in ("S", "A", "B")


def _price_diff_for_sort(r: dict) -> float:
    """現在価格と10年後推定価格の差額（万円）。差額が大きい順ソート用。"""
    price_man = r.get("price_man") or 0
    sim = simulate_10year_from_listing(r)
    price_10y = getattr(sim, "price_10y_man", 0) or 0 if sim else 0
    return price_man - price_10y


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
        m3_label, pg_label = get_destination_labels()
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
            _, rank, breakdown = get_asset_score_and_rank_with_breakdown(r)
            opt_10y, neu_10y, pes_10y = get_three_scenario_columns(r)
            monthly_loan, _ = get_loan_display_for_listing(r.get("price_man"))
            m3_str, pg_str = get_commute_display_with_estimate(r.get("station_line"), r.get("walk_min"))
            name = (r.get("name") or "")[:30]
            price = format_price(r.get("price_man"))
            layout = r.get("layout", "-")
            area = format_area(r.get("area_m2"))
            built = f"築{r.get('built_year', '-')}年" if r.get("built_year") else "-"
            walk = format_all_station_walk(r.get("station_line"), r.get("walk_min"))
            floor_str = format_floor(r.get("floor_position"), r.get("floor_total"))
            units = format_total_units(r.get("total_units"))
            address = (r.get("address") or "")[:20]
            gmap = google_maps_link(r.get("address") or "")
            urls = [x.get("url", "") for x in group if x.get("url")]
            if len(urls) == 1:
                link = f"[詳細]({urls[0]})"
            else:
                link = " ".join(f"[{i+1}]({u})" for i, u in enumerate(urls[:3]))
                if len(urls) > 3:
                    link += f" 他{len(urls)-3}件"
            lines.append(f"| {name} | {price} | {layout} | {area} | {built} | {walk} | {floor_str} | {units} | {rank} | {breakdown} | {opt_10y} | {neu_10y} | {pes_10y} | {monthly_loan} | {m3_str} | {pg_str} | {address} | {gmap} | {link} |")
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
        m3_label, pg_label = get_destination_labels()
        lines.extend([
            "## 🔄 価格変動",
            "",
            f"| 物件名 | 変更前 | 変更後 | 差額 | 間取り | 専有 | 階 | 総戸数 | 資産性(S/A/B/C) | 資産性根拠 | 楽観10年後 | 中立10年後 | 悲観10年後 | 月額(50年・諸経費3.5万) | {m3_label} | {pg_label} | Google Map | 詳細URL |",
            f"|--------|--------|--------|------|--------|------|-----|--------|----------------|------------|------------|------------|------------|------------------------|------|------|------------|---------|",
        ])
        for item in sorted(diff_a["updated"], key=lambda x: _price_diff_for_sort(x["current"]), reverse=True):
            curr = item["current"]
            prev = item["previous"]
            _, rank, breakdown = get_asset_score_and_rank_with_breakdown(curr)
            opt_10y, neu_10y, pes_10y = get_three_scenario_columns(curr)
            monthly_loan, _ = get_loan_display_for_listing(curr.get("price_man"))
            m3_str, pg_str = get_commute_display_with_estimate(curr.get("station_line"), curr.get("walk_min"))
            name = curr.get("name", "")[:30]
            prev_price = format_price(prev.get("price_man"))
            curr_price = format_price(curr.get("price_man"))
            diff_price = (curr.get("price_man") or 0) - (prev.get("price_man") or 0)
            diff_str = f"{'+' if diff_price >= 0 else ''}{diff_price}万円" if diff_price != 0 else "変動なし"
            layout = curr.get("layout", "-")
            area = format_area(curr.get("area_m2"))
            floor_str = format_floor(curr.get("floor_position"), curr.get("floor_total"))
            units = format_total_units(curr.get("total_units"))
            gmap = google_maps_link(curr.get("address") or "")
            url = curr.get("url", "")
            lines.append(f"| {name} | {prev_price} | {curr_price} | {diff_str} | {layout} | {area} | {floor_str} | {units} | {rank} | {breakdown} | {opt_10y} | {neu_10y} | {pes_10y} | {monthly_loan} | {m3_str} | {pg_str} | {gmap} | [詳細]({url}) |")
        lines.append("")

    # 削除された物件
    if diff_a and diff_a["removed"]:
        m3_label, pg_label = get_destination_labels()
        lines.extend([
            "## ❌ 削除された物件",
            "",
            f"| 物件名 | 価格 | 間取り | 専有 | 階 | 総戸数 | 資産性(S/A/B/C) | 資産性根拠 | 楽観10年後 | 中立10年後 | 悲観10年後 | 月額(50年・諸経費3.5万) | {m3_label} | {pg_label} | Google Map | 詳細URL |",
            f"|--------|------|--------|------|-----|--------|----------------|------------|------------|------------|------------|------------------------|------|------|------------|---------|",
        ])
        for r in sorted(diff_a["removed"], key=_price_diff_for_sort, reverse=True):
            _, rank, breakdown = get_asset_score_and_rank_with_breakdown(r)
            opt_10y, neu_10y, pes_10y = get_three_scenario_columns(r)
            monthly_loan, _ = get_loan_display_for_listing(r.get("price_man"))
            m3_str, pg_str = get_commute_display_with_estimate(r.get("station_line"), r.get("walk_min"))
            gmap = google_maps_link(r.get("address") or "")
            name = r.get("name", "")[:30]
            price = format_price(r.get("price_man"))
            layout = r.get("layout", "-")
            area = format_area(r.get("area_m2"))
            floor_str = format_floor(r.get("floor_position"), r.get("floor_total"))
            units = format_total_units(r.get("total_units"))
            url = r.get("url", "")
            lines.append(f"| {name} | {price} | {layout} | {area} | {floor_str} | {units} | {rank} | {breakdown} | {opt_10y} | {neu_10y} | {pes_10y} | {monthly_loan} | {m3_str} | {pg_str} | {gmap} | [詳細]({url}) |")
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
            m3_label, pg_label = get_destination_labels()
            lines.append(f"| 物件名 | 価格 | 間取り | 専有 | 築年 | 駅徒歩 | 所在地 | Google Map | 階 | 総戸数 | 資産性(S/A/B/C) | 資産性根拠 | 楽観10年後 | 中立10年後 | 悲観10年後 | 月額(50年・諸経費3.5万) | {m3_label} | {pg_label} | 詳細 |")
            lines.append("|--------|------|--------|------|------|--------|--------|------------|-----|--------|----------------|------------|------------|------------|------------|------------------------|------|------|------|")

            # 同名・同価格・同間取りで1行にまとめる。現在価格と10年後推定価格の差額が大きい順に表示
            merge_groups: dict[tuple, list[dict]] = defaultdict(list)
            for r in st_listings:
                merge_groups[row_merge_key(r)].append(r)
            for group in sorted(merge_groups.values(), key=lambda g: _price_diff_for_sort(g[0]), reverse=True):
                r = group[0]
                _, rank, breakdown = get_asset_score_and_rank_with_breakdown(r)
                opt_10y, neu_10y, pes_10y = get_three_scenario_columns(r)
                monthly_loan, _ = get_loan_display_for_listing(r.get("price_man"))
                m3_str, pg_str = get_commute_display_with_estimate(r.get("station_line"), r.get("walk_min"))
                name = (r.get("name") or "")[:30]
                price = format_price(r.get("price_man"))
                layout = r.get("layout", "-")
                area = format_area(r.get("area_m2"))
                built = f"築{r.get('built_year', '-')}年" if r.get("built_year") else "-"
                walk = format_all_station_walk(r.get("station_line"), r.get("walk_min"))
                address_short = format_address_from_ward(r.get("address") or "")
                gmap = google_maps_link(r.get("address") or "")
                floor_str = format_floor(r.get("floor_position"), r.get("floor_total"))
                units = format_total_units(r.get("total_units"))
                urls = [x.get("url", "") for x in group if x.get("url")]
                if len(urls) == 1:
                    link = f"[詳細]({urls[0]})"
                else:
                    link = " ".join(f"[{i+1}]({u})" for i, u in enumerate(urls[:3]))
                    if len(urls) > 3:
                        link += f" 他{len(urls)-3}件"
                lines.append(f"| {name} | {price} | {layout} | {area} | {built} | {walk} | {address_short} | {gmap} | {floor_str} | {units} | {rank} | {breakdown} | {opt_10y} | {neu_10y} | {pes_10y} | {monthly_loan} | {m3_str} | {pg_str} | {link} |")
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
