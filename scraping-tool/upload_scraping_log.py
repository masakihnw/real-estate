#!/usr/bin/env python3
"""
スクレイピングパイプラインのログを Firestore にアップロードする。

Firestore ドキュメント: scraping_logs/latest
iOS アプリからログを閲覧・コピーできるようにする。

使い方:
  python upload_scraping_log.py <log_file>
  python upload_scraping_log.py <log_file> --status success
  python upload_scraping_log.py <log_file> --status error
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path


# Firestore のドキュメントサイズ上限は 1MB。ログが長すぎる場合は末尾を優先して切り詰める。
MAX_LOG_BYTES = 900_000  # 900KB（余裕を持たせる）

JST = timezone(timedelta(hours=9))


def upload_log(log_path: str, status: str = "unknown") -> bool:
    """ログファイルを Firestore scraping_logs/latest にアップロードする。"""
    json_str = os.environ.get("FIREBASE_SERVICE_ACCOUNT")
    if not json_str or not json_str.strip():
        print("FIREBASE_SERVICE_ACCOUNT が未設定のためログアップロードをスキップ", file=sys.stderr)
        return False

    try:
        import firebase_admin
        from firebase_admin import credentials, firestore
    except ImportError:
        print("firebase-admin がインストールされていません", file=sys.stderr)
        return False

    try:
        cred_dict = json.loads(json_str)
    except json.JSONDecodeError as e:
        print(f"FIREBASE_SERVICE_ACCOUNT の JSON パースに失敗: {e}", file=sys.stderr)
        return False

    try:
        try:
            firebase_admin.get_app()
        except ValueError:
            cred = credentials.Certificate(cred_dict)
            firebase_admin.initialize_app(cred)
        db = firestore.client()
    except Exception as e:
        print(f"Firebase 初期化失敗: {e}", file=sys.stderr)
        return False

    # ログファイル読み込み
    log_file = Path(log_path)
    if not log_file.exists():
        print(f"ログファイルが見つかりません: {log_path}", file=sys.stderr)
        return False

    log_content = log_file.read_text(encoding="utf-8", errors="replace")

    # サイズ制限チェック（超過時は末尾を優先）
    truncated = False
    if len(log_content.encode("utf-8")) > MAX_LOG_BYTES:
        # 末尾から MAX_LOG_BYTES 分を切り出し
        encoded = log_content.encode("utf-8")
        truncated_bytes = encoded[-MAX_LOG_BYTES:]
        log_content = truncated_bytes.decode("utf-8", errors="replace")
        log_content = f"[... ログが長すぎるため先頭を省略 ...]\n\n{log_content}"
        truncated = True

    now = datetime.now(JST)

    data = {
        "log": log_content,
        "status": status,
        "timestamp": now.isoformat(),
        "truncated": truncated,
        "updatedAt": firestore.SERVER_TIMESTAMP,
    }

    try:
        db.collection("scraping_logs").document("latest").set(data)
        print(f"ログを Firestore にアップロードしました（{len(log_content)} 文字, status={status}）", file=sys.stderr)
        return True
    except Exception as e:
        print(f"Firestore アップロード失敗: {e}", file=sys.stderr)
        return False


def main():
    import argparse

    ap = argparse.ArgumentParser(description="スクレイピングログを Firestore にアップロード")
    ap.add_argument("log_file", help="アップロードするログファイルのパス")
    ap.add_argument("--status", choices=["success", "error", "unknown"], default="unknown",
                     help="パイプラインの実行結果ステータス")
    args = ap.parse_args()

    success = upload_log(args.log_file, args.status)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
