#!/usr/bin/env python3
from __future__ import annotations
"""
スクレイピング結果の差分を取得し、Slackに通知する。
Supabase の listing_events テーブルから前回通知以降のイベントを取得し、
新規追加・削除された物件のみ通知（価格変動は含めない）。
Supabase 未設定時は JSON ファイル比較にフォールバックする。
"""

import json
import os
import re
import sys
import unicodedata
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
    identity_key_str,
    load_json,
    normalize_listing_name,
)

from logger import get_logger
logger = get_logger(__name__)


def has_property_name(listing: dict[str, Any]) -> bool:
    """物件名が入っているか（純粋関数）。

    HOME'S 匿名掲載など物件名が伏せられた物件は建物特定が困難なため、
    新着 Slack 通知の対象から除外する（アプリ表示は listings_feed_light 側で除外）。
    """
    return bool((listing.get("name") or "").strip())


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


def _get_diff_from_supabase(client, current_listings: list[dict]) -> Optional[dict[str, list]]:
    """Supabase の listing_events から前回通知以降の差分を取得。
    compare_listings() と同じ形式 {"new": [...], "removed": [...]} を返す。
    失敗時は None を返し、呼び出し側で JSON フォールバックする。"""
    try:
        state = (client.table("notification_state")
                 .select("last_notified_at")
                 .eq("id", "slack")
                 .execute())
        if not state.data:
            logger.info("notification_state にレコードなし — 初回はスキップ（基準時刻を設定します）")
            _update_notification_state(client, "slack")
            return {"new": [], "removed": [], "updated": [], "unchanged": current_listings}

        last_at = state.data[0]["last_notified_at"]

        events_data: list[dict] = []
        offset = 0
        while True:
            resp = (client.table("listing_events")
                    .select("listing_id, event_type, occurred_at")
                    .gt("occurred_at", last_at)
                    .in_("event_type", ["appeared", "reappeared", "removed"])
                    .order("occurred_at")
                    .range(offset, offset + 999)
                    .execute())
            if not resp.data:
                break
            events_data.extend(resp.data)
            if len(resp.data) < 1000:
                break
            offset += 1000

        if not events_data:
            return {"new": [], "removed": [], "updated": [], "unchanged": current_listings, "_last_notified_at": last_at}

        listing_net: dict[int, str] = {}
        for e in events_data:
            lid = e["listing_id"]
            if e["event_type"] in ("appeared", "reappeared"):
                listing_net[lid] = "new"
            elif e["event_type"] == "removed":
                listing_net[lid] = "removed"

        # reappeared クールダウン: 直近 N 日以内に通知済みの再掲載はスキップ
        cooldown_days = int(os.environ.get("REAPPEAR_COOLDOWN_DAYS", "7"))
        appeared_this_period = {
            e["listing_id"] for e in events_data if e["event_type"] == "appeared"
        }
        reappeared_ids = list({
            e["listing_id"] for e in events_data
            if e["event_type"] == "reappeared"
            and listing_net.get(e["listing_id"]) == "new"
            and e["listing_id"] not in appeared_this_period
        })
        if reappeared_ids:
            from datetime import datetime, timedelta, timezone
            cooldown_since = (datetime.now(timezone.utc) - timedelta(days=cooldown_days)).isoformat()
            cooled: set[int] = set()
            for i in range(0, len(reappeared_ids), 100):
                batch = reappeared_ids[i:i + 100]
                prior = (client.table("listing_events")
                         .select("listing_id")
                         .in_("listing_id", batch)
                         .in_("event_type", ["appeared", "reappeared"])
                         .gt("occurred_at", cooldown_since)
                         .lte("occurred_at", last_at)
                         .execute())
                cooled.update(r["listing_id"] for r in (prior.data or []))
            for lid in cooled:
                del listing_net[lid]
            if cooled:
                logger.info("reappeared cooldown: %d listings suppressed (within %d days)", len(cooled), cooldown_days)

        new_ids = [lid for lid, s in listing_net.items() if s == "new"]
        removed_ids = [lid for lid, s in listing_net.items() if s == "removed"]

        current_by_ik: dict[str, dict] = {}
        for r in current_listings:
            ik = identity_key_str(r)
            if ik:
                current_by_ik[ik] = r

        new_listings: list[dict] = []
        if new_ids:
            for i in range(0, len(new_ids), 100):
                batch = new_ids[i:i + 100]
                rows = (client.table("listings")
                        .select("id, identity_key")
                        .in_("id", batch)
                        .execute())
                for row in (rows.data or []):
                    matched = current_by_ik.get(row["identity_key"])
                    # 物件名が伏せられた物件（HOME'S 匿名掲載など）は新着通知から除外する
                    if matched and has_property_name(matched):
                        new_listings.append(matched)

        removed_listings: list[dict] = []
        if removed_ids:
            for i in range(0, len(removed_ids), 100):
                batch = removed_ids[i:i + 100]
                rows = (client.table("listings")
                        .select("*")
                        .in_("id", batch)
                        .execute())
                enrich_rows = (client.table("enrichments")
                               .select("*")
                               .in_("listing_id", batch)
                               .execute())
                enrich_by_id = {r["listing_id"]: r for r in (enrich_rows.data or [])}
                source_rows = (client.table("listing_sources")
                               .select("listing_id, source, url, price_man")
                               .in_("listing_id", batch)
                               .order("last_seen_at", desc=True)
                               .execute())
                source_by_id: dict[int, dict] = {}
                for s in (source_rows.data or []):
                    source_by_id.setdefault(s["listing_id"], s)
                for row in (rows.data or []):
                    listing = dict(row)
                    listing.update(enrich_by_id.get(row["id"], {}))
                    src = source_by_id.get(row["id"], {})
                    listing.setdefault("price_man", src.get("price_man"))
                    listing.setdefault("url", src.get("url"))
                    listing.setdefault("source", src.get("source"))
                    # 無名物件は新着通知していない（表示もしていない）ため、
                    # 掲載終了も通知しない（新着/削除で一貫して無名は対象外）
                    if has_property_name(listing):
                        removed_listings.append(listing)

        logger.info("Supabase diff: new=%d removed=%d (since %s)", len(new_listings), len(removed_listings), last_at)
        return {"new": new_listings, "removed": removed_listings, "updated": [], "unchanged": [], "_last_notified_at": last_at}

    except Exception as e:
        logger.warning("Supabase diff 取得失敗（JSON フォールバック）: %s", e)
        return None


# ウォッチリスト値下げ通知の最小値下げ率。
# 単位は % （0.1 = 0.1%。RPC get_significant_price_changes のデフォルトは 5.0 = 5%）。
# いいね済み・高評価物件はわずかな値下げでも通知したいため、ノイズ除去程度の小さい閾値にしている。
WATCHLIST_MIN_DROP_PCT = 0.1


def _get_watchlist_price_drops(client, last_notified_at: str) -> list[dict]:
    """前回通知以降の値下げイベントのうち、いいね or S/A グレードの物件を返す。

    RPC get_significant_price_changes の change_pct は「正の値下げ率（%単位）」
    （migration 024 で old > new を WHERE 句で強制している）。
    例: 5000万 → 4800万 なら change_pct = 4.0。
    """
    try:
        drops = client.rpc("get_significant_price_changes", {
            "p_since": last_notified_at,
            "p_min_drop_pct": WATCHLIST_MIN_DROP_PCT,
        }).execute()
        if not drops.data:
            return []

        listing_ids = [d["listing_id"] for d in drops.data]

        # NOTE: 現在は単一ユーザー運用のため全ユーザーの is_liked を対象にしている。
        # マルチユーザー化する場合は user_id でのフィルタが必須（他ユーザーの
        # いいね物件が通知に混入する）
        ann = (client.table("user_annotations")
               .select("listing_identity_key")
               .eq("is_liked", True)
               .execute())
        liked_keys: set[str] = {r["listing_identity_key"] for r in (ann.data or [])}

        grade_by_id: dict[int, str] = {}
        for i in range(0, len(listing_ids), 100):
            batch = listing_ids[i:i + 100]
            rows = (client.table("enrichments")
                    .select("listing_id, asset_grade")
                    .in_("listing_id", batch)
                    .execute())
            for r in (rows.data or []):
                grade_by_id[r["listing_id"]] = r.get("asset_grade") or ""

        ik_by_id: dict[int, str] = {}
        for i in range(0, len(listing_ids), 100):
            batch = listing_ids[i:i + 100]
            rows = (client.table("listings")
                    .select("id, identity_key")
                    .in_("id", batch)
                    .execute())
            for r in (rows.data or []):
                ik_by_id[r["id"]] = r["identity_key"]

        result: list[dict] = []
        for d in drops.data:
            lid = d["listing_id"]
            ik = ik_by_id.get(lid, "")
            is_liked = ik in liked_keys
            grade = grade_by_id.get(lid, "")
            is_high_rated = grade in ("S", "A")
            if is_liked or is_high_rated:
                result.append({
                    "listing_id": lid,
                    "name": d["name"],
                    "old_price_man": d["old_price_man"],
                    "new_price_man": d["new_price_man"],
                    "change_pct": float(d["change_pct"]),
                    "changed_at": d["changed_at"],
                    "is_liked": is_liked,
                    "asset_grade": grade,
                })
        logger.info("Watchlist price drops: %d件 (since %s)", len(result), last_notified_at)
        return result
    except Exception as e:
        logger.warning("Watchlist 値下げ取得失敗: %s", e)
        return []


def build_watchlist_price_drop_section(drops: list[dict]) -> str:
    """注目物件の値下げ Slack セクションを組み立てる。"""
    if not drops:
        return ""
    lines = ["", "*💰 注目物件の値下げ*", "（お気に入り・高評価 S/A 物件）", ""]
    for d in sorted(drops, key=lambda x: x["change_pct"], reverse=True):
        badge = ""
        if d.get("is_liked"):
            badge += "❤️"
        if d.get("asset_grade") in ("S", "A"):
            badge += f"[{d['asset_grade']}]"
        name = (d.get("name") or "")[:30]
        old_p = format_price(d["old_price_man"])
        new_p = format_price(d["new_price_man"])
        diff_man = d["old_price_man"] - d["new_price_man"]
        pct = d["change_pct"]
        lines.append(f"  {badge} {name}")
        lines.append(f"    {old_p} → {new_p}（▼{diff_man}万円 / -{pct:.1f}%）")
    return "\n".join(lines)


def _get_noped_building_names(client) -> set[str]:
    """Supabase から nope 済み建物名を取得。identity_key の先頭セグメントを正規化して返す。"""
    try:
        resp = (client.table("user_building_preferences")
                .select("identity_key")
                .eq("preference", "nope")
                .execute())
        names: set[str] = set()
        for r in (resp.data or []):
            key = r.get("identity_key") or ""
            building = key.split("|", 1)[0].strip()
            if building:
                names.add(normalize_listing_name(building))
        return names
    except Exception as e:
        logger.warning("Nope 建物リスト取得失敗: %s", e)
        return set()


def _get_data_quality_issues(client) -> list[dict]:
    """建物名が空または極端に短いアクティブ物件を返す（データ品質アラート用）。"""
    try:
        resp = (client.table("listings")
                .select("id, name, normalized_name, address")
                .eq("is_active", True)
                .execute())

        issues = []
        for r in (resp.data or []):
            name = (r.get("name") or "").strip()
            normalized = (r.get("normalized_name") or "").strip()
            if not name or len(normalized) <= 3:
                issues.append(r)

        if not issues:
            return []

        listing_ids = [r["id"] for r in issues]
        url_by_id: dict[int, tuple[str, str]] = {}
        for i in range(0, len(listing_ids), 100):
            batch = listing_ids[i:i + 100]
            src_resp = (client.table("listing_sources")
                        .select("listing_id, source, url")
                        .in_("listing_id", batch)
                        .eq("is_active", True)
                        .execute())
            for s in (src_resp.data or []):
                lid = s["listing_id"]
                if lid not in url_by_id:
                    url_by_id[lid] = (s["source"], s["url"])

        result = []
        for r in issues:
            source, url = url_by_id.get(r["id"], ("", ""))
            result.append({
                "id": r["id"],
                "name": r.get("name") or "",
                "normalized_name": r.get("normalized_name") or "",
                "address": (r.get("address") or "").replace("東京都", ""),
                "source": source,
                "url": url,
            })

        logger.info("データ品質問題: %d件検出", len(result))
        return result
    except Exception as e:
        logger.warning("データ品質チェック失敗: %s", e)
        return []


def build_data_quality_alert_section(issues: list[dict]) -> Optional[str]:
    """建物名なし物件の手動調査依頼セクションを組み立てる。"""
    if not issues:
        return None

    lines = [
        "",
        "🔧 *建物名データ品質アラート*",
        f"建物名が空または不正な物件が {len(issues)} 件あります。掲載ページで確認し Supabase を更新してください。",
        "",
    ]

    for r in issues:
        name_display = r["name"] or "（空）"
        address = r["address"] or "住所不明"
        source = r["source"] or "不明"
        url = r["url"]

        lines.append(f"  • *ID {r['id']}* | {name_display} | {address} | ソース: {source}")
        if url:
            lines.append(f"    <{url}|掲載ページを確認>")

    return "\n".join(lines)


def _build_scraper_health_section() -> Optional[str]:
    """scraper_metrics の閾値超過アラート（パース失敗率・空ページ）をセクション化。"""
    try:
        import scraper_metrics
        health = scraper_metrics.load()
        if health.get("alerts"):
            lines = ["*⚠️ スクレイパー健全性アラート*"]
            lines += [f"  • {a}" for a in health["alerts"]]
            return "\n".join(lines)
    except Exception as e:
        logger.warning("スクレイパー健全性アラートの取得失敗: %s", e)
    return None


def _send_health_alerts(default_webhook_url: str, data_quality_issues: list[dict]) -> bool:
    """スクレイパー健全性アラート・建物名データ品質アラートを専用チャンネルへ送信する。

    物件更新通知（SLACK_WEBHOOK_URL）とは別チャンネルに分離する。送信先は
    SLACK_HEALTH_WEBHOOK_URL。未設定時は取りこぼし防止のため既定 webhook に
    フォールバックする。送信すべきアラートが無ければ何もせず True を返す。
    """
    sections: list[str] = []
    health_section = _build_scraper_health_section()
    if health_section:
        sections.append(health_section)
    dq_section = build_data_quality_alert_section(data_quality_issues)
    if dq_section:
        sections.append(dq_section.strip("\n"))
    if not sections:
        return True

    target_url = os.environ.get("SLACK_HEALTH_WEBHOOK_URL") or default_webhook_url
    message = "\n\n".join(sections)
    if send_slack_message_chunked_with_retry(target_url, message):
        logger.info("スクレイパー健全性・データ品質アラートを送信しました")
        return True
    logger.error("スクレイパー健全性・データ品質アラートの送信に失敗しました")
    return False


def _update_notification_state(client, channel: str = "slack", expected_last: str | None = None) -> None:
    """通知成功後に last_notified_at を更新する。
    expected_last が指定された場合は CAS: 値が一致する場合のみ更新する。"""
    try:
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).isoformat()
        if expected_last:
            result = (client.table("notification_state")
                      .update({"last_notified_at": now, "updated_at": now})
                      .eq("id", channel)
                      .eq("last_notified_at", expected_last)
                      .execute())
            if not result.data:
                logger.warning("notification_state CAS 失敗 — 別プロセスが先に更新済み")
                return
        else:
            client.table("notification_state").upsert(
                {"id": channel, "last_notified_at": now, "updated_at": now},
                on_conflict="id",
            ).execute()
        logger.info("notification_state.last_notified_at を更新しました")
    except Exception as e:
        logger.error("notification_state 更新失敗: %s", e)
        raise


def build_slack_message_from_listings(
    current: list[dict[str, Any]],
    previous: Optional[list[dict[str, Any]]],
    report_url: Optional[str] = None,
    map_url: Optional[str] = None,
    diff_override: Optional[dict[str, list]] = None,
) -> str:
    """Slack用にメッセージを組み立てる。新規追加・削除のみ表示。資産性B以上の物件のみ。
    diff_override が渡された場合は compare_listings を呼ばずにその diff を使う。"""
    current_a = [r for r in current if optional_features.get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
    diff = diff_override if diff_override is not None else (compare_listings(current, previous) if previous else {})
    diff_new_a = [r for r in diff.get("new", []) if optional_features.get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
    diff_removed_a = [r for r in diff.get("removed", []) if (optional_features.get_asset_score_and_rank(r)[1] or "B") in ("S", "A", "B")]

    # --- 同一物件の再登録を検出して除外 ---
    # 階+価格+面積+築年が一致し、同一建物（住所+築年）であれば同一部屋の再掲載とみなす
    def _normalize_layout_for_match(layout: str | None) -> str:
        s = unicodedata.normalize("NFKC", (layout or "").strip())
        s = re.sub(r"\s*[(（][^)）]*[)）]", "", s)
        s = re.sub(r"^(\d+)S(LDK|LK|DK|K)(.*)$", r"\1\2+S\3", s)
        s = re.sub(r"[+＋]S", "+S", s)
        return s

    def _unit_fingerprint(r: dict) -> tuple:
        """同一部屋判定: 階+面積+築年（価格・間取り表記は揺れが多いため除外）"""
        return (
            r.get("area_m2"),
            r.get("floor_position"),
            r.get("built_year"),
        )

    def _building_key_for_swap(r: dict) -> tuple:
        from report_utils import _normalize_address_for_key
        addr = _normalize_address_for_key(r.get("address") or "")
        addr = re.sub(r"(\d+)丁目.*$", r"\1", addr)
        return (addr, r.get("built_year"))

    relisted_new_ids: set[int] = set()
    relisted_removed_ids: set[int] = set()
    removed_fps = [(_unit_fingerprint(r), _building_key_for_swap(r), i) for i, r in enumerate(diff_removed_a)]
    for nr in diff_new_a:
        nfp = _unit_fingerprint(nr)
        nbk = _building_key_for_swap(nr)
        for rfp, rbk, ri in removed_fps:
            if nfp == rfp and nbk == rbk and id(diff_removed_a[ri]) not in relisted_removed_ids:
                relisted_new_ids.add(id(nr))
                relisted_removed_ids.add(id(diff_removed_a[ri]))
                break

    effective_new = [r for r in diff_new_a if id(r) not in relisted_new_ids]
    effective_removed = [r for r in diff_removed_a if id(r) not in relisted_removed_ids]

    # --- 同一マンション内の入れ替え検出 ---
    # 住所+築年でグルーピング（マンション名の表記揺れに依存しない）
    new_by_bldg: dict[tuple, list[dict]] = {}
    for r in effective_new:
        bk = _building_key_for_swap(r)
        new_by_bldg.setdefault(bk, []).append(r)
    removed_by_bldg: dict[tuple, list[dict]] = {}
    for r in effective_removed:
        bk = _building_key_for_swap(r)
        removed_by_bldg.setdefault(bk, []).append(r)

    swap_buildings = set(new_by_bldg) & set(removed_by_bldg)
    swap_buildings = {bk for bk in swap_buildings if bk[0]}
    swap_new_ids = {id(r) for b in swap_buildings for r in new_by_bldg[b]}
    swap_removed_ids = {id(r) for b in swap_buildings for r in removed_by_bldg[b]}
    pure_new = [r for r in effective_new if id(r) not in swap_new_ids]
    pure_removed = [r for r in effective_removed if id(r) not in swap_removed_ids]

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

    # ■ 今回の変更
    if swap_buildings or pure_new or pure_removed:
        lines.append("*■ 今回の変更*")
        if swap_buildings:
            lines.append(f"  🔄 *入れ替え*: {len(swap_buildings)}棟")
        if pure_new:
            lines.append(f"  🆕 *新規追加*: {len(pure_new)}件")
        if pure_removed:
            lines.append(f"  ❌ *削除*: {len(pure_removed)}件")
        lines.append("")

    # 同一マンション内の入れ替え
    if swap_buildings:
        lines.append("*🔄 同一マンション内の入れ替え*")
        for bk in sorted(swap_buildings, key=lambda k: (new_by_bldg[k][0].get("name") or "")):
            removed_units = removed_by_bldg[bk]
            new_units = new_by_bldg[bk]
            display_name = (new_units[0].get("name") or removed_units[0].get("name") or "")[:28]
            rem_parts = []
            for r in removed_units:
                fp = r.get("floor_position")
                p = format_price(r.get("price_man"))
                rem_parts.append(f"{fp}階 {p}" if fp else p)
            new_parts = []
            for r in new_units:
                fp = r.get("floor_position")
                p = format_price(r.get("price_man"))
                new_parts.append(f"{fp}階 {p}" if fp else p)
            lines.append(f"• {display_name}: {', '.join(rem_parts)} → 削除 / {', '.join(new_parts)} → 新規")
        lines.append("")

    # 新規追加された物件（入れ替え分を除く、価格昇順）
    if pure_new:
        lines.append("*🆕 新規追加された物件*")
        for r in sorted(pure_new, key=lambda x: x.get("price_man") or 0):
            url = r.get("url", "")
            lines.append(_listing_line_slack(r, url))
        lines.append("")

    # 削除された物件（入れ替え分を除く）
    if pure_removed:
        lines.append("*❌ 削除された物件*")
        for r in pure_removed:
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


def _pop_morning_digest(client: Any) -> tuple[str, int | None]:
    """最新の pending new_listing_digest を1件返し、古い pending は skipped にする。"""
    try:
        result = client.rpc("get_pending_notification_drafts", {"p_channel": "slack"}).execute()
        digests = [d for d in (result.data or []) if d["notification_type"] == "new_listing_digest"]
        digests.sort(key=lambda d: d.get("draft_date", ""), reverse=True)
        latest_msg, latest_id = "", None
        for i, draft in enumerate(digests):
            if i == 0:
                msg = (draft.get("message_text") or "").strip()
                if msg:
                    latest_msg, latest_id = msg, draft["id"]
                    continue
            try:
                client.rpc("mark_notification_sent", {"p_id": draft["id"], "p_status": "skipped"}).execute()
                logger.info("古い new_listing_digest (id=%d, date=%s) を skipped", draft["id"], draft.get("draft_date"))
            except Exception:
                pass
        return latest_msg, latest_id
    except Exception as e:
        logger.warning("new_listing_digest 取得失敗: %s", e)
    return "", None


WEBHOOK_OVERRIDES: dict[str, str] = {
    "pipeline_health_report": "SLACK_HEALTH_WEBHOOK_URL",
}


def _send_notification_drafts(client: Any, webhook_url: str) -> tuple[int, int]:
    """notification_drafts テーブルから pending ドラフトを読み出して Slack 送信。
    Returns (sent_count, failed_count)."""
    try:
        result = client.rpc("get_pending_notification_drafts", {"p_channel": "slack"}).execute()
        drafts = result.data or []
    except Exception as e:
        logger.warning("notification_drafts 読み出し失敗（テーブル未作成 or RPC 未定義の可能性）: %s", e)
        return 0, 0

    SKIP_TYPES = {"health_report", "daily_brief"}

    from datetime import date
    today_str = date.today().isoformat()

    sent = 0
    failed = 0
    for draft in drafts:
        draft_id = draft["id"]
        ntype = draft["notification_type"]
        msg = draft.get("message_text") or ""

        # 当日分の new_listing_digest は朝の本通知への統合（_pop_morning_digest）を
        # 待つため pending のまま残す。翌日以降も残っていればフォールバック送信する。
        if ntype == "new_listing_digest" and draft.get("draft_date") == today_str:
            logger.info("notification_draft 保留（当日 digest は朝の統合待ち）: id=%d", draft_id)
            continue

        if ntype in SKIP_TYPES:
            try:
                client.rpc("mark_notification_sent", {"p_id": draft_id, "p_status": "skipped"}).execute()
            except Exception:
                pass
            continue

        if not msg.strip():
            try:
                client.rpc("mark_notification_sent", {"p_id": draft_id, "p_status": "skipped"}).execute()
            except Exception:
                pass
            continue

        target_url = webhook_url
        override_env = WEBHOOK_OVERRIDES.get(ntype)
        if override_env:
            target_url = os.environ.get(override_env) or webhook_url

        ok = send_slack_message_chunked_with_retry(target_url, msg)
        try:
            if ok:
                client.rpc("mark_notification_sent", {"p_id": draft_id, "p_status": "sent"}).execute()
                sent += 1
                logger.info("notification_draft 送信完了: id=%d type=%s", draft_id, ntype)
            else:
                client.rpc("mark_notification_sent", {
                    "p_id": draft_id,
                    "p_status": "failed",
                    "p_error": "Slack webhook send failed after retries",
                }).execute()
                failed += 1
                logger.error("notification_draft 送信失敗: id=%d type=%s", draft_id, ntype)
        except Exception as e:
            logger.error("notification_draft ステータス更新失敗: %s", e)
            failed += 1

    if sent > 0 or failed > 0:
        logger.info("notification_drafts: %d 送信, %d 失敗", sent, failed)
    return sent, failed


def main() -> None:
    """メイン処理。Supabase 優先、未設定時は JSON フォールバック。"""
    if len(sys.argv) < 2:
        logger.info("使い方: python slack_notify.py <current.json> [previous.json] [report.md]")
        sys.exit(1)

    current_path = Path(sys.argv[1])
    previous_path = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
    report_path = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None

    webhook_url = os.environ.get("SLACK_WEBHOOK_URL")
    if not webhook_url:
        logger.warning("警告: SLACK_WEBHOOK_URL 環境変数が設定されていません（通知をスキップ）")
        sys.exit(0)

    current = load_json(current_path, missing_ok=True, default=[])

    # --- Supabase ベースの差分取得を試行 ---
    supabase_client = None
    diff = None
    try:
        from supabase_client import get_client
        supabase_client = get_client()
    except ImportError:
        pass

    if supabase_client:
        diff = _get_diff_from_supabase(supabase_client, current)

    # --- Supabase 失敗時は JSON フォールバック ---
    if diff is None:
        fallback_path = previous_path or current_path.parent / "previous_slack.json"
        if not fallback_path.exists():
            fallback_path = current_path.parent / "previous.json"
        previous = load_json(fallback_path, missing_ok=True, default=[])
        diff = compare_listings(current, previous) if previous else {}
        logger.info("JSON フォールバックで差分を取得しました")

    # --- Nope 建物を除外 ---
    noped = _get_noped_building_names(supabase_client) if supabase_client else set()
    if noped:
        for key in ("new", "removed"):
            diff[key] = [r for r in diff.get(key, [])
                         if normalize_listing_name(r.get("name") or "") not in noped]

    # --- 注目物件の値下げ取得 ---
    watchlist_drops: list[dict] = []
    last_notified_at = diff.get("_last_notified_at") if diff else None
    if supabase_client and last_notified_at:
        watchlist_drops = _get_watchlist_price_drops(supabase_client, last_notified_at)

    # --- データ品質問題の取得（建物名なし物件） ---
    data_quality_issues: list[dict] = []
    if supabase_client:
        data_quality_issues = _get_data_quality_issues(supabase_client)

    # --- スクレイパー健全性・建物名データ品質アラートを専用チャンネルへ送信 ---
    # これらは物件更新通知（SLACK_WEBHOOK_URL）とは別チャンネル
    # （SLACK_HEALTH_WEBHOOK_URL）に分離する。本文の有無に関わらず、
    # アラートがあれば独立して送信する。
    _send_health_alerts(webhook_url, data_quality_issues)

    # --- 通知判定 ---
    diff_new_a = [r for r in diff.get("new", []) if optional_features.get_asset_score_and_rank(r)[1] in ("S", "A", "B")]
    diff_removed_a = [r for r in diff.get("removed", []) if (optional_features.get_asset_score_and_rank(r)[1] or "B") in ("S", "A", "B")]

    # pending な AI ダイジェストがあれば、この回で統合送信する（1日1回、最初の GHA が拾う）。
    # ここで一度だけ取得し、後段の本文組み立てでも同じ結果を再利用する
    # （二重取得は冗長なうえ、並行ランナーとの競合窓を広げる）
    digest_text = ""
    digest_draft_id = None
    if supabase_client:
        digest_text, digest_draft_id = _pop_morning_digest(supabase_client)
    has_pending_digest = bool(digest_text)

    # データ品質アラートは別チャンネルへ送信済みのため、本通知の判定には含めない
    has_content = diff_new_a or diff_removed_a or has_pending_digest or watchlist_drops

    if not has_content:
        if supabase_client:
            _send_notification_drafts(supabase_client, webhook_url)
        logger.warning("変更なし（資産性B以上の新規・削除なし、注目値下げなし）Slack通知をスキップします")
        sys.exit(0)
    elif not diff_new_a and diff_removed_a and not has_pending_digest and not watchlist_drops:
        if supabase_client:
            _send_notification_drafts(supabase_client, webhook_url)
        logger.warning("削除のみの変更 — AI ダイジェストもなし、通知を保留します")
        sys.exit(0)

    # --- URL 組み立て ---
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

    # --- メッセージ組み立て・送信 ---
    message = build_slack_message_from_listings(current, None, report_url, map_url=map_url, diff_override=diff)

    # 注目物件の値下げセクションを追加
    if watchlist_drops:
        message = message + "\n" + build_watchlist_price_drop_section(watchlist_drops)

    # ※ スクレイパー健全性アラート・建物名データ品質アラートは別チャンネル
    #   （SLACK_HEALTH_WEBHOOK_URL）へ _send_health_alerts() で送信済み。

    # pending な AI ダイジェストを本文末尾に統合（Routine 2 が1日1回生成。上で取得済み）
    if digest_text:
        message = message + "\n\n" + digest_text

    if send_slack_message_chunked_with_retry(webhook_url, message):
        logger.info("Slack通知を送信しました")
        last_at = diff.get("_last_notified_at") if diff else None
        if supabase_client and last_at:
            _update_notification_state(supabase_client, "slack", expected_last=last_at)
        if digest_draft_id and supabase_client:
            try:
                supabase_client.rpc("mark_notification_sent", {"p_id": digest_draft_id, "p_status": "sent"}).execute()
                logger.info("new_listing_digest (id=%d) を朝通知に統合送信しました", digest_draft_id)
            except Exception as e:
                logger.warning("new_listing_digest ステータス更新失敗: %s", e)
    else:
        logger.error("Slack通知の送信に失敗しました（リトライ後も送信できませんでした）")
        sys.exit(1)

    if supabase_client:
        _send_notification_drafts(supabase_client, webhook_url)


if __name__ == "__main__":
    main()
