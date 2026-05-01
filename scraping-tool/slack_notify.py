#!/usr/bin/env python3
"""
スクレイピング結果の差分を取得し、Slackに通知する。
前回結果（latest.json）と現在結果を比較し、新規追加・削除された物件のみ通知（価格変動は含めない）。
"""

import json
import os
import sys
from pathlib import Path
from typing import Any, Optional

from optional_features import optional_features
from report_utils import (
    best_address,
    compare_listings,
    format_area,
    format_floor,
    format_ownership,
    format_price,
    format_total_units,
    google_maps_url,
    load_json,
)

from logger import get_logger
logger = get_logger(__name__)



def format_diff_message(
    diff: dict[str, Any],
    current_count: int,
    report_url: Optional[str] = None,
    map_url: Optional[str] = None,
) -> str:
    """差分をSlackメッセージ形式に整形。report_url / map_url が指定されていればそのリンクを使う。新規・削除のみ。"""
    new_count = len(diff["new"])
    removed_count = len(diff["removed"])

    lines = [
        "🏠 *中古マンション物件情報 更新通知*",
        "",
        f"📊 *現在の件数*: {current_count}件",
        "",
    ]

    if new_count > 0 or removed_count > 0:
        lines.append("*📈 変更サマリー*")
        if new_count > 0:
            lines.append(f"  🆕 新規: {new_count}件")
        if removed_count > 0:
            lines.append(f"  ❌ 削除: {removed_count}件")
        lines.append("")

    # 新規物件（全件表示）
    if diff["new"]:
        lines.append("*🆕 新規物件*")
        for r in sorted(diff["new"], key=lambda x: x.get("price_man") or 0):
            name = r.get("name", "")[:40]
            price = format_price(r.get("price_man"))
            layout = r.get("layout", "-")
            area_str = format_area(r.get("area_m2"))
            lines.append(f"  • {name}")
            lines.append(f"    {price} | {layout} | {area_str}")
        lines.append("")

    # 削除された物件（全件表示）
    if diff["removed"]:
        lines.append("*❌ 削除された物件*")
        for r in diff["removed"]:
            name = r.get("name", "")[:40]
            price = format_price(r.get("price_man"))
            lines.append(f"  • {name} ({price})")
        lines.append("")

    if new_count == 0 and removed_count == 0:
        lines.append("変更はありませんでした。")

    lines.append("")
    if report_url:
        lines.append(f"📄 詳細: <{report_url}|レポートを確認>")
    else:
        repo = os.environ.get("GITHUB_REPOSITORY", "masakihnw/dev-workspace")
        ref = os.environ.get("GITHUB_REF_NAME") or (
            (os.environ.get("GITHUB_REF") or "").replace("refs/heads/", "").replace("refs/tags/", "") or "main"
        )
        lines.append(f"📄 詳細: <https://github.com/{repo}/blob/{ref}/scraping-tool/results/report/report.md|レポートを確認>")
    if map_url:
        lines.append(f"📌 地図: <{map_url}|地図で見る（スマホ可）>")

    return "\n".join(lines)


# 1投稿あたりの文字数上限（Slack推奨は40000未満。余裕を持たせる）
SLACK_CHUNK_SIZE = 35000
# 1チャンク送信の最大リトライ回数
SLACK_SEND_RETRIES = 5
# リトライ間隔（秒）
SLACK_RETRY_DELAY_SEC = 2


def send_slack_message(webhook_url: str, message: str) -> bool:
    """Slack Incoming Webhookにメッセージを1通送信。"""
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
        logger.error(f"Slack送信エラー: {e}")
        return False


def send_slack_message_chunked_with_retry(webhook_url: str, message: str) -> bool:
    """メッセージをチャンクに分割し、全チャンクを送信し切るまでリトライする。"""
    import time

    if not message.strip():
        return True
    chunks: list[str] = []
    rest = message
    while rest:
        if len(rest) <= SLACK_CHUNK_SIZE:
            chunks.append(rest)
            break
        # 行境界で分割（長い行の途中で切らない）
        cut = rest[:SLACK_CHUNK_SIZE]
        last_nl = cut.rfind("\n")
        if last_nl > SLACK_CHUNK_SIZE // 2:
            chunks.append(rest[: last_nl + 1])
            rest = rest[last_nl + 1 :]
        else:
            chunks.append(cut)
            rest = rest[SLACK_CHUNK_SIZE:]
    for i, chunk in enumerate(chunks):
        for attempt in range(SLACK_SEND_RETRIES):
            if send_slack_message(webhook_url, chunk):
                if len(chunks) > 1:
                    logger.info(f"Slack: チャンク {i + 1}/{len(chunks)} 送信完了")
                break
            if attempt < SLACK_SEND_RETRIES - 1:
                time.sleep(SLACK_RETRY_DELAY_SEC)
                logger.info(f"Slack: チャンク {i + 1} リトライ ({attempt + 2}/{SLACK_SEND_RETRIES})")
        else:
            logger.info(f"Slack: チャンク {i + 1}/{len(chunks)} が送信できませんでした（リトライ上限）")
            return False
    return True


def report_url_from_current_path(current_path: Path) -> Optional[str]:
    """current_YYYYMMDD_HHMMSS.json のパスから、その実行のレポート GitHub URL を組み立てる。"""
    stem = current_path.stem  # e.g. current_20260128_074236
    if not stem.startswith("current_"):
        return None
    timestamp = stem[8:]  # 20260128_074236
    report_filename = f"report_{timestamp}.md"
    repo = os.environ.get("GITHUB_REPOSITORY", "masakihnw/dev-workspace")
    ref = os.environ.get("GITHUB_REF_NAME") or (
        (os.environ.get("GITHUB_REF") or "").replace("refs/heads/", "").replace("refs/tags/", "") or "main"
    )
    base = f"https://github.com/{repo}/blob/{ref}/scraping-tool/results"
    return f"{base}/{report_filename}"


def report_url_from_report_path(report_path: Path) -> Optional[str]:
    """report_YYYYMMDD_HHMMSS.md のパスから GitHub URL を組み立てる。"""
    if not report_path or not report_path.name.startswith("report_") or not report_path.name.endswith(".md"):
        return None
    repo = os.environ.get("GITHUB_REPOSITORY", "masakihnw/dev-workspace")
    ref = os.environ.get("GITHUB_REF_NAME") or (
        (os.environ.get("GITHUB_REF") or "").replace("refs/heads/", "").replace("refs/tags/", "") or "main"
    )
    base = f"https://github.com/{repo}/blob/{ref}/scraping-tool/results"
    return f"{base}/{report_path.name}"


def map_url_from_report_url(report_url: Optional[str]) -> Optional[str]:
    """
    GitHub のレポート URL から、同一リポジトリの map_viewer.html を
    htmlpreview で開く URL を組み立てる。スマホからも閲覧可能。
    """
    if not report_url or "github.com" not in report_url or "/blob/" not in report_url:
        return None
    # https://github.com/OWNER/REPO/blob/BRANCH/path 形式 → raw URL
    raw = report_url.replace("github.com", "raw.githubusercontent.com").replace("/blob/", "/")
    if "report/report.md" in raw:
        raw = raw.replace("report/report.md", "map_viewer.html")
    elif "results/report.md" in raw or raw.endswith("/report.md"):
        raw = raw.replace("results/report.md", "results/map_viewer.html").replace("/report.md", "/map_viewer.html")
    else:
        raw = raw.rstrip("/").rsplit("/", 1)[0] + "/map_viewer.html" if "/" in raw else raw + "/map_viewer.html"
    return f"https://htmlpreview.github.io/?{raw}"


# Slack メッセージの上限（余裕を持って）
SLACK_TEXT_LIMIT = 35000


def _listing_line_slack(r: dict, url: str = "", include_breakdown: bool = True) -> str:
    """1物件をSlack用1行に。戸数・階数・権利・資産性・10年後(中立)・通勤時間（M3・PG）を必ず含む。"""
    _, rank, breakdown = optional_features.get_asset_score_and_rank_with_breakdown(r)
    _, neu_10y, _ = optional_features.get_three_scenario_columns(r)
    m3_str, pg_str = optional_features.get_commute_display_with_estimate(r.get("station_line"), r.get("walk_min"))
    name = (r.get("name") or "")[:28]
    price = format_price(r.get("price_man"))
    layout = r.get("layout", "-")
    area = format_area(r.get("area_m2"))
    built = f"築{r.get('built_year', '-')}年" if r.get("built_year") else "-"
    walk = optional_features.format_all_station_walk(r.get("station_line"), r.get("walk_min"))
    # 戸数・階数・権利は必ず表示（取得できない場合は「戸数:不明」「階:-」「権利:不明」）
    floor_str = format_floor(r.get("floor_position"), r.get("floor_total"), r.get("floor_structure"))
    units = format_total_units(r.get("total_units"))
    ownership_str = format_ownership(r.get("ownership"))
    parts = [name, price, layout, area, built, walk, floor_str, units, ownership_str, rank]
    if include_breakdown:
        parts.append(breakdown)
    parts.append(f"10年後:{neu_10y}")
    monthly_loan, _ = optional_features.get_loan_display_for_listing(r.get("price_man"))
    parts.extend([f"月額:{monthly_loan}"])
    parts.extend([f"M3:{m3_str}", f"PG:{pg_str}"])
    line = "• " + " ｜ ".join(parts)
    map_url_val = google_maps_url(r.get("name") or best_address(r))
    if map_url_val:
        line += f" ｜ <{map_url_val}|Map>"
    if url:
        line += f" ｜ <{url}|詳細>"
    return line


def build_slack_message_from_listings(
    current: list[dict[str, Any]],
    previous: Optional[list[dict[str, Any]]],
    report_url: Optional[str] = None,
    map_url: Optional[str] = None,
) -> str:
    """Slack用にメッセージを組み立てる。新規追加・削除のみ表示。資産性B以上の物件のみ。レポート・地図はリンクで提供。"""
    # 資産性B以上に絞る
    current_a = [r for r in current if optional_features.get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
    diff = compare_listings(current, previous) if previous else {}
    diff_new_a = [r for r in diff.get("new", []) if optional_features.get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
    diff_removed_a = [r for r in diff.get("removed", []) if optional_features.get_asset_score_and_rank(r)[1] in ("S", "A", "B")]

    new_c = len(diff_new_a)
    rem_c = len(diff_removed_a)

    lines = [
        "🏠 *中古マンション物件情報*（資産性B以上のみ）",
        "",
        f"📊 対象件数: {len(current_a)}件（B以上 / 全{len(current)}件中）",
        "",
    ]
    # レポート・ピン付き地図へのリンクを冒頭で表示（見逃し防止）
    if report_url:
        lines.append(f"📄 <{report_url}|レポートを確認>")
    if map_url:
        lines.append(f"📌 <{map_url}|物件のピン付き地図で見る>")
    if report_url or map_url:
        lines.append("")

    # ■ 今回の変更（新規追加・削除のみ）
    if new_c or rem_c:
        lines.append("*■ 今回の変更*")
        lines.append(f"  🆕 *新規追加*: {new_c}件")
        lines.append(f"  ❌ *削除*: {rem_c}件")
        lines.append("")

    # 新規追加された物件（全件表示、価格昇順）
    if diff_new_a:
        lines.append("*🆕 新規追加された物件*")
        for r in sorted(diff_new_a, key=lambda x: x.get("price_man") or 0):
            url = r.get("url", "")
            lines.append(_listing_line_slack(r, url))
        lines.append("")

    # 削除された物件（全件表示）。戸数・階数・権利を必ず含める
    if diff_removed_a:
        lines.append("*❌ 削除された物件*")
        for r in diff_removed_a:
            floor_str = format_floor(r.get("floor_position"), r.get("floor_total"), r.get("floor_structure"))
            units = format_total_units(r.get("total_units"))
            ownership_str = format_ownership(r.get("ownership"))
            map_url_val = google_maps_url(r.get("name") or best_address(r))
            map_part = f" ｜ <{map_url_val}|Map>" if map_url_val else ""
            lines.append(f"• {(r.get('name') or '')[:28]} ｜ {format_price(r.get('price_man'))} ｜ {floor_str} ｜ {units} ｜ {ownership_str}{map_part}")
        lines.append("")

    # 末尾にもレポート・地図リンク（冒頭で既に出しているが、長文の最後にも）
    if report_url:
        lines.append(f"📄 <{report_url}|レポートを確認>")
    else:
        lines.append("📄 レポート: GitHub の results/report を確認")
    if map_url:
        lines.append(f"📌 <{map_url}|物件のピン付き地図で見る>")

    return "\n".join(lines)


def build_bargain_alert_message(new_listings: list[dict]) -> Optional[str]:
    """NEW かつ asset_score rank S/A の物件があれば即時アラートメッセージを生成。"""
    bargains = []
    for r in new_listings:
        _, rank = optional_features.get_asset_score_and_rank(r)
        if rank in ("S", "A"):
            bargains.append((r, rank))
    if not bargains:
        return None

    lines = ["\U0001f525 *割安物件を検出*", ""]
    for r, rank in sorted(bargains, key=lambda x: x[0].get("price_man") or 0):
        name = (r.get("name") or "")[:35]
        price = format_price(r.get("price_man"))
        layout = r.get("layout", "-")
        # Include source info if alt_sources present
        sources = ", ".join(r.get("alt_sources") or [r.get("source") or ""])
        lines.append(f"  \U0001f3f7️ [{rank}ランク] {name}")
        lines.append(f"    {price} | {layout} | 掲載: {sources}")
        url = r.get("url", "")
        if url:
            lines.append(f"    <{url}|詳細を見る>")
    lines.append("")
    lines.append("_通常の更新通知は次回の定期実行で送信されます_")
    return "\n".join(lines)


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
        logger.info("使い方: python slack_notify.py <current.json> [previous.json] [report.md]")
        sys.exit(1)

    current_path = Path(sys.argv[1])
    previous_path = Path(sys.argv[2]) if len(sys.argv) > 2 else current_path.parent / "latest.json"
    report_path = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None

    webhook_url = os.environ.get("SLACK_WEBHOOK_URL")
    if not webhook_url:
        logger.warning("警告: SLACK_WEBHOOK_URL 環境変数が設定されていません（通知をスキップ）")
        sys.exit(0)  # エラーではなく警告として扱い、ワークフローは続行

    current = load_json(current_path, missing_ok=True, default=[])
    previous = load_json(previous_path, missing_ok=True, default=[]) if previous_path else []

    # 通知判定:
    #   - 新規追加あり → 毎回通知
    #   - 削除のみ → 朝の回（JST 9:00 = UTC 0）だけ通知
    #   - 変更なし → スキップ
    from datetime import datetime, timezone
    current_utc_hour = datetime.now(timezone.utc).hour
    is_morning = current_utc_hour in (0, 1)  # UTC 0-1 = JST 9-10時台
    if previous:
        diff = compare_listings(current, previous)
        diff_new_a = [r for r in diff.get("new", []) if optional_features.get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
        diff_removed_a = [r for r in diff.get("removed", []) if optional_features.get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
        if not diff_new_a and not diff_removed_a:
            logger.warning("変更なし（資産性B以上の新規・削除なし）Slack通知をスキップします")
            sys.exit(0)
        elif not diff_new_a and diff_removed_a and not is_morning:
            logger.warning("削除のみの変更 — 朝の回（JST 9:00）まで通知を保留します")
            sys.exit(0)

    # CI（GitHub Actions）では GITHUB_REPOSITORY / GITHUB_REF_NAME から正しい URL を組み立てる
    repo = os.environ.get("GITHUB_REPOSITORY")
    ref = os.environ.get("GITHUB_REF_NAME") or (
        (os.environ.get("GITHUB_REF") or "").replace("refs/heads/", "").replace("refs/tags/", "")
    )
    if repo and ref:
        report_url = f"https://github.com/{repo}/blob/{ref}/scraping-tool/results/report/report.md"
        map_url = f"https://htmlpreview.github.io/?https://raw.githubusercontent.com/{repo}/{ref}/scraping-tool/results/map_viewer.html"
    else:
        report_url = report_url_from_report_path(report_path) if report_path else report_url_from_current_path(current_path)
        map_url = map_url_from_report_url(report_url)
    # Slack用はMarkdown表を使わない見やすい形式で投稿。長文はチャンク分割し、送り切れるまでリトライする。
    message = build_slack_message_from_listings(current, previous, report_url, map_url=map_url)

    if send_slack_message_chunked_with_retry(webhook_url, message):
        logger.info("Slack通知を送信しました")
    else:
        logger.error("Slack通知の送信に失敗しました（リトライ後も送信できませんでした）")
        sys.exit(1)


if __name__ == "__main__":
    main()
