#!/usr/bin/env python3
"""
Firebase Cloud Messaging (FCM) HTTP v1 API でプッシュ通知を送信する。

使い方:
  python3 scripts/send_push.py --new-count 5
  python3 scripts/send_push.py --new-count 3 --shinchiku-count 2
  python3 scripts/send_push.py --new-count 2 --latest results/latest.json --latest-shinchiku results/latest_shinchiku.json

環境変数:
  FIREBASE_SERVICE_ACCOUNT  -- Firebase サービスアカウント JSON（文字列）
  FIREBASE_PROJECT_ID       -- Firebase プロジェクト ID（サービスアカウント JSON にも含まれるがフォールバック用）
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import date
from pathlib import Path

import requests

# FCM v1 API エンドポイント
FCM_SEND_URL = "https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"

# OAuth2 トークンエンドポイント
TOKEN_URL = "https://oauth2.googleapis.com/token"

# FCM スコープ
FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"


def get_access_token(service_account: dict) -> str:
    """サービスアカウント JSON から OAuth2 アクセストークンを取得する。"""
    import jwt as pyjwt  # PyJWT

    now = int(time.time())
    payload = {
        "iss": service_account["client_email"],
        "sub": service_account["client_email"],
        "aud": TOKEN_URL,
        "iat": now,
        "exp": now + 3600,
        "scope": FCM_SCOPE,
    }

    # RS256 で署名
    signed_jwt = pyjwt.encode(
        payload,
        service_account["private_key"],
        algorithm="RS256",
    )

    # アクセストークンを取得
    resp = requests.post(TOKEN_URL, data={
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": signed_jwt,
    }, timeout=30)
    resp.raise_for_status()
    return resp.json()["access_token"]


def send_topic_push(
    project_id: str,
    access_token: str,
    topic: str,
    title: str,
    body: str,
    max_retries: int = 3,
) -> bool:
    """FCM HTTP v1 API でトピックにプッシュ通知を送信する。失敗時はリトライ（最大 max_retries 回）。"""
    url = FCM_SEND_URL.format(project_id=project_id)

    message = {
        "message": {
            "topic": topic,
            "notification": {
                "title": title,
                "body": body,
            },
            "apns": {
                "payload": {
                    "aps": {
                        "sound": "default",
                        "badge": 1,
                    }
                }
            },
        }
    }

    for attempt in range(max_retries):
        try:
            resp = requests.post(
                url,
                headers={
                    "Authorization": f"Bearer {access_token}",
                    "Content-Type": "application/json",
                },
                json=message,
                timeout=30,
            )

            if resp.status_code == 200:
                print(f"プッシュ通知送信成功: {title}", file=sys.stderr)
                return True
            elif resp.status_code in (500, 502, 503) and attempt < max_retries - 1:
                wait = 2 ** (attempt + 1)
                print(f"プッシュ通知送信失敗 ({resp.status_code})、{wait}秒後にリトライ ({attempt + 1}/{max_retries})", file=sys.stderr)
                time.sleep(wait)
                continue
            else:
                print(f"プッシュ通知送信失敗: {resp.status_code} {resp.text}", file=sys.stderr)
                return False
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout) as e:
            if attempt < max_retries - 1:
                wait = 2 ** (attempt + 1)
                print(f"プッシュ通知送信エラー: {e}、{wait}秒後にリトライ ({attempt + 1}/{max_retries})", file=sys.stderr)
                time.sleep(wait)
            else:
                print(f"プッシュ通知送信失敗（リトライ上限）: {e}", file=sys.stderr)
                return False

    return False


def _detect_price_changes(listings: list[dict], today: str) -> dict:
    """直近の価格変動を検出する。"""
    decreases = []
    increases = []
    for r in listings:
        history = r.get("price_history")
        if not history or len(history) < 2:
            continue
        latest = history[-1]
        prev = history[-2]
        if latest.get("date") != today:
            continue
        diff = latest.get("price_man", 0) - prev.get("price_man", 0)
        if diff < 0:
            decreases.append({"name": r.get("name", "?"), "diff": diff})
        elif diff > 0:
            increases.append({"name": r.get("name", "?"), "diff": diff})
    return {"decreases": decreases, "increases": increases}


def _format_price_change_summary(changes: list[dict], max_examples: int = 3) -> str:
    """価格変動のサマリを通知用にフォーマット（例: パークタワー -300万、シティタワー -150万）。"""
    parts = []
    for item in changes[:max_examples]:
        name = (item.get("name") or "?").strip()
        if len(name) > 12:
            name = name[:10] + "…"
        diff = item.get("diff", 0)
        parts.append(f"{name} {diff:+d}万")
    return "、".join(parts)


def main() -> None:
    ap = argparse.ArgumentParser(description="FCM でプッシュ通知を送信")
    ap.add_argument("--new-count", type=int, default=0, help="新着中古件数")
    ap.add_argument("--shinchiku-count", type=int, default=0, help="新着新築件数")
    ap.add_argument("--latest", type=str, default="", help="中古 latest.json のパス（価格変動検出用）")
    ap.add_argument("--latest-shinchiku", type=str, default="", help="新築 latest_shinchiku.json のパス（価格変動検出用）")
    args = ap.parse_args()

    # 価格変動の検出（--latest 指定時）
    price_changes: dict = {"decreases": [], "increases": []}
    if args.latest:
        today = date.today().isoformat()
        all_listings: list[dict] = []
        for path_str in [args.latest, args.latest_shinchiku]:
            if not path_str:
                continue
            path = Path(path_str)
            if path.exists():
                try:
                    with open(path, "r", encoding="utf-8") as f:
                        all_listings.extend(json.load(f))
                except (json.JSONDecodeError, OSError) as e:
                    print(f"警告: {path} の読み込みに失敗: {e}", file=sys.stderr)
        if all_listings:
            detected = _detect_price_changes(all_listings, today)
            price_changes["decreases"] = detected["decreases"]
            price_changes["increases"] = detected["increases"]

    total = args.new_count + args.shinchiku_count
    has_price_changes = bool(price_changes["decreases"] or price_changes["increases"])
    if total <= 0 and not has_price_changes:
        print("新着・価格変動なし、通知をスキップ", file=sys.stderr)
        return

    # サービスアカウント JSON
    sa_json = os.environ.get("FIREBASE_SERVICE_ACCOUNT", "")
    if not sa_json:
        print("FIREBASE_SERVICE_ACCOUNT が未設定のためスキップ", file=sys.stderr)
        return

    try:
        service_account = json.loads(sa_json)
    except json.JSONDecodeError:
        print("FIREBASE_SERVICE_ACCOUNT の JSON パースに失敗", file=sys.stderr)
        return

    project_id = service_account.get("project_id", "")
    if not project_id:
        project_id = os.environ.get("FIREBASE_PROJECT_ID", "")
    if not project_id:
        print("Firebase Project ID が見つかりません", file=sys.stderr)
        return

    # アクセストークン取得
    try:
        access_token = get_access_token(service_account)
    except Exception as e:
        print(f"アクセストークン取得失敗: {e}", file=sys.stderr)
        return

    # 通知メッセージ組み立て
    parts = []
    if args.new_count > 0:
        parts.append(f"中古 {args.new_count}件")
    if args.shinchiku_count > 0:
        parts.append(f"新築 {args.shinchiku_count}件")
    if price_changes["decreases"]:
        summary = _format_price_change_summary(price_changes["decreases"])
        parts.append(f"値下げ {len(price_changes['decreases'])}件（{summary}）")
    if price_changes["increases"]:
        summary = _format_price_change_summary(price_changes["increases"])
        parts.append(f"値上げ {len(price_changes['increases'])}件（{summary}）")

    title = "新着・価格変動" if has_price_changes else "新着物件"
    body = " / ".join(parts) if parts else "価格変動がありました。"
    if total > 0 and not has_price_changes:
        body = f"{body} の新規物件が追加されました。"

    send_topic_push(project_id, access_token, "new_listings", title, body)


if __name__ == "__main__":
    main()
