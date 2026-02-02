#!/usr/bin/env python3
"""
スクレイピング結果の差分を取得し、Slackに通知する。
前回結果（latest.json）と現在結果を比較して、新規・価格変動・削除を検出。
"""

import json
import os
import sys
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urljoin

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
    def get_loan_display_for_listing(price_man: Any) -> tuple[str, str]:
        return "-", "-"

try:
    from commute import get_commute_display_with_estimate
except ImportError:
    def get_commute_display_with_estimate(station_line: str, walk_min: Optional[int]) -> tuple[str, str]:
        return ("-", "-")

try:
    from generate_report import (
        compare_listings,
        format_price,
        format_area,
        format_floor,
        format_total_units,
        get_three_scenario_columns,
        get_ward_from_address,
        get_station_group,
        row_merge_key,
        TOKYO_23_WARDS,
    )
    from commute import format_all_station_walk
except ImportError:
    # generate_report / commute がインポートできない場合のフォールバック
    def compare_listings(current: list[dict], previous: Optional[list[dict]] = None) -> dict[str, Any]:
        if not previous:
            return {"new": current, "updated": [], "removed": []}
        current_by_url = {r["url"]: r for r in current}
        previous_by_url = {r["url"]: r for r in previous}
        new = [curr for url, curr in current_by_url.items() if url not in previous_by_url]
        updated = [
            {"current": curr, "previous": previous_by_url[url]}
            for url, curr in current_by_url.items()
            if url in previous_by_url and curr.get("price_man") != previous_by_url[url].get("price_man")
        ]
        removed = [prev for url, prev in previous_by_url.items() if url not in current_by_url]
        return {"new": new, "updated": updated, "removed": removed}

    def format_price(price_man: Optional[int]) -> str:
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
        return f"{area_m2:.1f}㎡" if area_m2 else "-"

    def format_walk(walk_min: Optional[int]) -> str:
        return f"徒歩{walk_min}分" if walk_min is not None else "-"

    def format_all_station_walk(station_line: str, fallback_walk_min: Optional[int]) -> str:
        return format_walk(fallback_walk_min) if fallback_walk_min is not None else "-"

    def format_floor(floor_position: Any, floor_total: Any) -> str:
        if floor_position is not None and floor_position >= 0 and floor_total is not None and floor_total >= 1:
            return f"{floor_position}階/{floor_total}階建"
        if floor_position is not None and floor_position >= 0:
            return f"{floor_position}階"
        if floor_total is not None and floor_total >= 1:
            return f"{floor_total}階建"
        return "階:-"

    def format_total_units(total_units: Optional[int]) -> str:
        return f"{total_units}戸" if total_units else "戸数:不明"

    def get_three_scenario_columns(r: dict) -> tuple[str, str, str]:
        return "-", "-", "-"

    def get_ward_from_address(address: str) -> str:
        return ""

    def get_station_group(station_line: str) -> str:
        return (station_line or "")[:25] or "(駅情報なし)"

    def row_merge_key(r: dict) -> tuple:
        name = (r.get("name") or "").strip()
        name_norm = "".join(name.split())  # 全角・半角スペースを除いて同一判定
        return (name_norm, r.get("price_man"), (r.get("layout") or "").strip())

    TOKYO_23_WARDS = ()


def load_json(path: Path) -> list[dict[str, Any]]:
    """JSONファイルを読み込む。"""
    if not path.exists():
        return []
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def format_diff_message(diff: dict[str, Any], current_count: int, report_url: Optional[str] = None) -> str:
    """差分をSlackメッセージ形式に整形。report_url が指定されていればそのリンクを使う。"""
    new_count = len(diff["new"])
    updated_count = len(diff["updated"])
    removed_count = len(diff["removed"])

    lines = [
        "🏠 *中古マンション物件情報 更新通知*",
        "",
        f"📊 *現在の件数*: {current_count}件",
        "",
    ]

    if new_count > 0 or updated_count > 0 or removed_count > 0:
        lines.append("*📈 変更サマリー*")
        if new_count > 0:
            lines.append(f"  🆕 新規: {new_count}件")
        if updated_count > 0:
            lines.append(f"  🔄 価格変動: {updated_count}件")
        if removed_count > 0:
            lines.append(f"  ❌ 削除: {removed_count}件")
        lines.append("")

    # 新規物件（最大5件）
    if diff["new"]:
        lines.append("*🆕 新規物件*")
        for r in sorted(diff["new"], key=lambda x: x.get("price_man") or 0)[:5]:
            name = r.get("name", "")[:40]
            price = format_price(r.get("price_man"))
            layout = r.get("layout", "-")
            area = r.get("area_m2")
            area_str = f"{area:.1f}㎡" if area else "-"
            lines.append(f"  • {name}")
            lines.append(f"    {price} | {layout} | {area_str}")
        if len(diff["new"]) > 5:
            lines.append(f"  ... 他 {len(diff['new']) - 5}件")
        lines.append("")

    # 価格変動（最大5件、差額が大きい順）
    if diff["updated"]:
        lines.append("*🔄 価格変動*")
        sorted_updated = sorted(
            diff["updated"],
            key=lambda x: abs((x["current"].get("price_man") or 0) - (x["previous"].get("price_man") or 0)),
            reverse=True,
        )
        for item in sorted_updated[:5]:
            curr = item["current"]
            prev = item["previous"]
            name = curr.get("name", "")[:40]
            prev_price = format_price(prev.get("price_man"))
            curr_price = format_price(curr.get("price_man"))
            diff_price = (curr.get("price_man") or 0) - (prev.get("price_man") or 0)
            diff_str = f"{'+' if diff_price >= 0 else ''}{diff_price}万円"
            lines.append(f"  • {name}")
            lines.append(f"    {prev_price} → {curr_price} ({diff_str})")
        if len(diff["updated"]) > 5:
            lines.append(f"  ... 他 {len(diff['updated']) - 5}件")
        lines.append("")

    # 削除された物件（最大5件）
    if diff["removed"]:
        lines.append("*❌ 削除された物件*")
        for r in diff["removed"][:5]:
            name = r.get("name", "")[:40]
            price = format_price(r.get("price_man"))
            lines.append(f"  • {name} ({price})")
        if len(diff["removed"]) > 5:
            lines.append(f"  ... 他 {len(diff['removed']) - 5}件")
        lines.append("")

    if new_count == 0 and updated_count == 0 and removed_count == 0:
        lines.append("変更はありませんでした。")

    lines.append("")
    if report_url:
        lines.append(f"📄 詳細: <{report_url}|レポートを確認>")
    else:
        lines.append("📄 詳細: <https://github.com/masakihnw/dev-workspace/blob/main/personal/projects/real-estate/scraping-tool/results/report/report.md|レポートを確認>")

    return "\n".join(lines)


def send_slack_message(webhook_url: str, message: str) -> bool:
    """Slack Incoming Webhookにメッセージを送信。"""
    import urllib.request
    import urllib.parse

    payload = {"text": message}
    data = json.dumps(payload).encode("utf-8")

    try:
        req = urllib.request.Request(
            webhook_url,
            data=data,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status == 200
    except Exception as e:
        print(f"Slack送信エラー: {e}", file=sys.stderr)
        return False


def report_url_from_current_path(current_path: Path) -> Optional[str]:
    """current_YYYYMMDD_HHMMSS.json のパスから、その実行のレポート GitHub URL を組み立てる。"""
    stem = current_path.stem  # e.g. current_20260128_074236
    if not stem.startswith("current_"):
        return None
    timestamp = stem[8:]  # 20260128_074236
    report_filename = f"report_{timestamp}.md"
    base = "https://github.com/masakihnw/dev-workspace/blob/main/personal/projects/real-estate/scraping-tool/results"
    return f"{base}/{report_filename}"


def report_url_from_report_path(report_path: Path) -> Optional[str]:
    """report_YYYYMMDD_HHMMSS.md のパスから GitHub URL を組み立てる。"""
    if not report_path or not report_path.name.startswith("report_") or not report_path.name.endswith(".md"):
        return None
    base = "https://github.com/masakihnw/dev-workspace/blob/main/personal/projects/real-estate/scraping-tool/results"
    return f"{base}/{report_path.name}"


# Slack メッセージの上限（余裕を持って）
SLACK_TEXT_LIMIT = 35000


def _listing_line_slack(r: dict, url: str = "", include_breakdown: bool = True) -> str:
    """1物件をSlack用1行に。総戸数・資産性・根拠・楽観/中立/悲観10年後・通勤時間（M3・PG）含む。"""
    _, rank, breakdown = get_asset_score_and_rank_with_breakdown(r)
    opt_10y, neu_10y, pes_10y = get_three_scenario_columns(r)
    m3_str, pg_str = get_commute_display_with_estimate(r.get("station_line"), r.get("walk_min"))
    name = (r.get("name") or "")[:28]
    price = format_price(r.get("price_man"))
    layout = r.get("layout", "-")
    area = format_area(r.get("area_m2"))
    built = f"築{r.get('built_year', '-')}年" if r.get("built_year") else "-"
    walk = format_all_station_walk(r.get("station_line"), r.get("walk_min"))
    floor_str = format_floor(r.get("floor_position"), r.get("floor_total"))
    units = format_total_units(r.get("total_units"))
    parts = [name, price, layout, area, built, walk, floor_str, units, rank]
    if include_breakdown:
        parts.append(breakdown)
    parts.extend([f"楽観:{opt_10y}", f"中立:{neu_10y}", f"悲観:{pes_10y}"])
    monthly_loan, _ = get_loan_display_for_listing(r.get("price_man"))
    parts.extend([f"月額:{monthly_loan}"])
    parts.extend([f"M3:{m3_str}", f"PG:{pg_str}"])
    line = "• " + " ｜ ".join(parts)
    if url:
        line += f" ｜ <{url}|詳細>"
    return line


def build_slack_message_from_listings(
    current: list[dict[str, Any]],
    previous: Optional[list[dict[str, Any]]],
    report_url: Optional[str] = None,
) -> str:
    """Slack用にMarkdown表を使わず、見やすいテキスト形式でメッセージを組み立てる。資産性B以上の物件のみ。"""
    from collections import defaultdict

    # 資産性B以上に絞る
    current_a = [r for r in current if get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
    diff = compare_listings(current, previous) if previous else {}
    diff_new_a = [r for r in diff.get("new", []) if get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
    diff_updated_a = [item for item in diff.get("updated", []) if get_asset_score_and_rank(item.get("current", {}))[1] in ("S", "A", "B")]
    diff_removed_a = [r for r in diff.get("removed", []) if get_asset_score_and_rank(r)[1] in ("S", "A", "B")]

    new_c = len(diff_new_a)
    upd_c = len(diff_updated_a)
    rem_c = len(diff_removed_a)

    lines = [
        "🏠 *中古マンション物件情報*（資産性B以上のみ）",
        "",
        f"📊 対象件数: {len(current_a)}件（B以上 / 全{len(current)}件中）",
        "",
    ]

    # ■ 今回の変更（新規追加・削除・価格変動を冒頭で明示）
    if new_c or upd_c or rem_c:
        lines.append("*■ 今回の変更*")
        lines.append(f"  🆕 *新規追加*: {new_c}件")
        lines.append(f"  ❌ *削除*: {rem_c}件")
        lines.append(f"  🔄 *価格変動*: {upd_c}件")
        lines.append("")

    # 新規追加された物件（区に関係なく一番上）
    if diff_new_a:
        lines.append("*🆕 新規追加された物件*")
        for r in sorted(diff_new_a, key=lambda x: x.get("price_man") or 0)[:10]:
            url = r.get("url", "")
            lines.append(_listing_line_slack(r, url))
        if len(diff_new_a) > 10:
            lines.append(f"  … 他 {len(diff_new_a) - 10}件")
        lines.append("")

    # 価格変動した物件（最大5件）
    if diff_updated_a:
        lines.append("*🔄 価格変動した物件*")
        for item in sorted(
            diff_updated_a,
            key=lambda x: abs((x["current"].get("price_man") or 0) - (x["previous"].get("price_man") or 0)),
            reverse=True,
        )[:5]:
            c = item["current"]
            prev_p = format_price(item["previous"].get("price_man"))
            curr_p = format_price(c.get("price_man"))
            lines.append(f"• {(c.get('name') or '')[:28]} ｜ {prev_p} → {curr_p} ｜ <{c.get('url', '')}|詳細>")
        if len(diff_updated_a) > 5:
            lines.append(f"  … 他 {len(diff_updated_a) - 5}件")
        lines.append("")

    # 削除された物件（最大5件）
    if diff_removed_a:
        lines.append("*❌ 削除された物件*")
        for r in diff_removed_a[:5]:
            lines.append(f"• {(r.get('name') or '')[:28]} ｜ {format_price(r.get('price_man'))}")
        if len(diff_removed_a) > 5:
            lines.append(f"  … 他 {len(diff_removed_a) - 5}件")
        lines.append("")

    # 物件一覧（区・駅別、資産性B以上のみ）
    ward_order = {w: i for i, w in enumerate(TOKYO_23_WARDS)}
    by_ward: dict[str, list[dict]] = defaultdict(list)
    for r in current_a:
        ward = get_ward_from_address(r.get("address") or "")
        if ward:
            by_ward[ward].append(r)
        else:
            by_ward["(区不明)"].append(r)
    ordered_wards = sorted(by_ward.keys(), key=lambda w: ward_order.get(w, 999))

    lines.append("*📋 物件一覧（区・駅別・資産性B以上）*")
    lines.append("  _物件名 ｜ 価格 ｜ … ｜ 楽観10年後 ｜ 中立10年後 ｜ 悲観10年後 ｜ 月額(50年・諸経費3.5万) ｜ M3 ｜ PG ｜ 詳細_")
    lines.append("")
    for ward in ordered_wards:
        ward_listings = by_ward.get(ward, [])
        if not ward_listings:
            continue
        lines.append(f"*{ward}*")
        by_station: dict[str, list[dict]] = defaultdict(list)
        for r in ward_listings:
            st = get_station_group(r.get("station_line") or "")
            by_station[st].append(r)
        for station in sorted(by_station.keys()):
            st_listings = by_station[station]
            merge_groups: dict[tuple, list[dict]] = defaultdict(list)
            for r in st_listings:
                merge_groups[row_merge_key(r)].append(r)
            for group in sorted(merge_groups.values(), key=lambda g: (g[0].get("price_man") or 0)):
                r = group[0]
                urls = [x.get("url", "") for x in group if x.get("url")]
                url = urls[0] if urls else ""
                lines.append(f"  _{station}_")
                lines.append(f"  {_listing_line_slack(r, url)}")
        lines.append("")

    if report_url:
        lines.append(f"📄 <{report_url}|レポートを確認>")
    else:
        lines.append("📄 レポート: GitHub の results/report を確認")

    out = "\n".join(lines)
    if len(out) > SLACK_TEXT_LIMIT:
        out = out[:SLACK_TEXT_LIMIT] + "\n\n… (文字数制限のため省略。詳細は下記リンクから)"
    return out


def build_message_from_report(report_path: Path, report_url: Optional[str] = None) -> Optional[str]:
    """レポート md ファイルの中身を読み取り、Slack 投稿文にする。※Slack用には build_slack_message_from_listings を推奨。"""
    if not report_path or not report_path.exists():
        return None
    try:
        content = report_path.read_text(encoding="utf-8").strip()
    except Exception:
        return None
    if len(content) > SLACK_TEXT_LIMIT:
        content = content[:SLACK_TEXT_LIMIT] + "\n\n... (文字数制限のため省略。詳細は下記リンクから)"
    if report_url:
        content += f"\n\n📄 詳細: <{report_url}|レポートを確認>"
    return content


def main() -> None:
    """メイン処理。"""
    if len(sys.argv) < 2:
        print("使い方: python slack_notify.py <current.json> [previous.json] [report.md]", file=sys.stderr)
        sys.exit(1)

    current_path = Path(sys.argv[1])
    previous_path = Path(sys.argv[2]) if len(sys.argv) > 2 else current_path.parent / "latest.json"
    report_path = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None

    webhook_url = os.environ.get("SLACK_WEBHOOK_URL")
    if not webhook_url:
        print("警告: SLACK_WEBHOOK_URL 環境変数が設定されていません（通知をスキップ）", file=sys.stderr)
        sys.exit(0)  # エラーではなく警告として扱い、ワークフローは続行

    current = load_json(current_path)
    previous = load_json(previous_path) if previous_path.exists() else None

    # 投稿対象は資産性B以上のみ。前回ありかつB以上に絞った差分がなければ投稿をスキップする
    if previous:
        diff = compare_listings(current, previous)
        diff_new_a = [r for r in diff.get("new", []) if get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
        diff_updated_a = [item for item in diff.get("updated", []) if get_asset_score_and_rank(item.get("current", {}))[1] in ("S", "A", "B")]
        diff_removed_a = [r for r in diff.get("removed", []) if get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
        if not diff_new_a and not diff_updated_a and not diff_removed_a:
            print("変更なし（資産性B以上の新規・削除・価格変動なし）Slack通知をスキップします", file=sys.stderr)
            sys.exit(0)

    report_url = report_url_from_report_path(report_path) if report_path else report_url_from_current_path(current_path)
    # Slack用はMarkdown表を使わない見やすい形式で投稿（総戸数含む）。レポートMDはGitHub用に残し、投稿内容はJSONから生成。
    message = build_slack_message_from_listings(current, previous, report_url)

    if send_slack_message(webhook_url, message):
        print("Slack通知を送信しました", file=sys.stderr)
    else:
        print("Slack通知の送信に失敗しました", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
