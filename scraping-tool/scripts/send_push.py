#!/usr/bin/env python3
"""
Firebase Cloud Messaging (FCM) HTTP v1 API でプッシュ通知を送信する。

使い方:
  python3 scripts/send_push.py --new-count 5
  python3 scripts/send_push.py --new-count 3 --shinchiku-count 2

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


def main() -> None:
    ap = argparse.ArgumentParser(description="FCM でプッシュ通知を送信")
    ap.add_argument("--new-count", type=int, default=0, help="新着中古件数")
    ap.add_argument("--shinchiku-count", type=int, default=0, help="新着新築件数")
    args = ap.parse_args()

    total = args.new_count + args.shinchiku_count
    if total <= 0:
        print("新着なし、通知をスキップ", file=sys.stderr)
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

    title = "新着物件"
    body = f"{', '.join(parts)} の新規物件が追加されました。"

    send_topic_push(project_id, access_token, "new_listings", title, body)


if __name__ == "__main__":
    main()
