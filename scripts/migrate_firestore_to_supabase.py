#!/usr/bin/env python3
"""
Firestore → Supabase アノテーション移行スクリプト

Firestore の annotations コレクションを読み取り、
Supabase の user_annotations テーブルに移行する。

前提:
  - GOOGLE_APPLICATION_CREDENTIALS 環境変数に Firebase サービスアカウント JSON のパスを設定
  - SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY 環境変数を設定

使用方法:
  pip install firebase-admin supabase
  export GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceAccountKey.json
  export SUPABASE_URL=https://xxx.supabase.co
  export SUPABASE_SERVICE_ROLE_KEY=xxx
  python scripts/migrate_firestore_to_supabase.py
"""

import os
import sys
import json
from datetime import datetime, timezone

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except ImportError:
    print("Error: firebase-admin パッケージが必要です。pip install firebase-admin")
    sys.exit(1)

try:
    from supabase import create_client
except ImportError:
    print("Error: supabase パッケージが必要です。pip install supabase")
    sys.exit(1)


def init_firebase():
    """Firebase Admin SDK を初期化"""
    cred_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not cred_path:
        print("Error: GOOGLE_APPLICATION_CREDENTIALS 環境変数を設定してください")
        sys.exit(1)
    cred = credentials.Certificate(cred_path)
    firebase_admin.initialize_app(cred)
    return firestore.client()


def init_supabase():
    """Supabase クライアントを初期化"""
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        print("Error: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY 環境変数を設定してください")
        sys.exit(1)
    return create_client(url, key)


def parse_firestore_comments(comments_map: dict) -> list:
    """
    Firestore のコメント map を JSON 配列に変換。
    Firestore: { commentId: { text, authorName, authorId, createdAt } }
    Supabase:  [ { id, text, authorName, authorId, createdAt, editedAt? } ]
    """
    if not comments_map:
        return []

    result = []
    for comment_id, data in comments_map.items():
        if not isinstance(data, dict):
            continue
        comment = {
            "id": comment_id,
            "text": data.get("text", ""),
            "authorName": data.get("authorName", "不明"),
            "authorId": data.get("authorId", ""),
            "createdAt": _timestamp_to_iso(data.get("createdAt")),
        }
        if "editedAt" in data and data["editedAt"]:
            comment["editedAt"] = _timestamp_to_iso(data["editedAt"])
        result.append(comment)

    result.sort(key=lambda c: c.get("createdAt", ""))
    return result


def _timestamp_to_iso(ts) -> str:
    """Firestore Timestamp → ISO 8601 文字列"""
    if ts is None:
        return datetime.now(timezone.utc).isoformat()
    if hasattr(ts, "seconds"):
        dt = datetime.fromtimestamp(ts.seconds + ts.nanos / 1e9, tz=timezone.utc)
        return dt.isoformat()
    if isinstance(ts, datetime):
        return ts.isoformat()
    return str(ts)


def migrate():
    print("=" * 60)
    print("Firestore → Supabase アノテーション移行")
    print("=" * 60)

    db = init_firebase()
    supabase = init_supabase()

    # Firestore の annotations コレクションを全件取得
    print("\n[1/3] Firestore から annotations を読み取り中...")
    docs = db.collection("annotations").stream()

    records = []
    for doc in docs:
        data = doc.to_dict()
        if not data:
            continue

        # Firestore ドキュメントからデータを抽出
        is_liked = data.get("isLiked", False)
        memo = data.get("memo")
        comments_map = data.get("comments", {})
        name = data.get("name", "")

        # コメントを JSON 配列に変換
        comments = parse_firestore_comments(comments_map)

        # レガシー memo → コメント変換
        if not comments and memo:
            updated_at = data.get("updatedAt")
            comments = [{
                "id": "legacy",
                "text": memo,
                "authorName": "メモ",
                "authorId": "",
                "createdAt": _timestamp_to_iso(updated_at),
            }]
            memo = None

        # identity_key の復元: Firestore の docID = SHA256(identityKey)[:16]
        # → 逆引き不可のため、listing名で検索するか直接 identity_key を保存する必要がある
        # ここでは doc_id をメタデータとして保持し、後で iOS が自動マッピングする
        # 実際には iOS 側で identityKey → docID の対応を持っているので
        # ここでは Firestore に保存されている全データを Supabase に移す

        # ユーザー情報: Firestore のドキュメントには user_id が直接ないため
        # コメントの authorId から推定するか、全ユーザー共有として扱う
        # → 家族アプリなので、最初のコメント or isLiked を操作したユーザーを推定
        user_id = _infer_user_id(data)

        record = {
            "doc_id": doc.id,
            "user_id": user_id,
            "is_liked": is_liked,
            "memo": memo,
            "comments": comments if comments else None,
            "name": name,
        }
        records.append(record)

    print(f"  → {len(records)} 件のアノテーションを取得")

    if not records:
        print("\n移行対象なし。終了。")
        return

    # identity_key のマッピング: Supabase の listings テーブルから取得
    print("\n[2/3] Supabase から listings の identity_key マッピングを取得中...")
    identity_key_map = _build_identity_key_map(supabase, records)
    print(f"  → {len(identity_key_map)} 件のマッピングを取得")

    # Supabase に書き込み
    print("\n[3/3] Supabase に書き込み中...")
    success = 0
    skipped = 0
    errors = 0

    for record in records:
        doc_id = record["doc_id"]
        identity_key = identity_key_map.get(doc_id)

        if not identity_key:
            skipped += 1
            continue

        row = {
            "user_id": record["user_id"] or "shared",
            "listing_identity_key": identity_key,
            "is_liked": record["is_liked"],
            "memo": record["memo"],
            "comments": json.dumps(record["comments"]) if record["comments"] else None,
        }

        try:
            supabase.table("user_annotations").upsert(
                row, on_conflict="user_id,listing_identity_key"
            ).execute()
            success += 1
        except Exception as e:
            print(f"  Error ({doc_id}): {e}")
            errors += 1

    print(f"\n{'=' * 60}")
    print(f"完了: {success} 件成功, {skipped} 件スキップ, {errors} 件エラー")
    print(f"{'=' * 60}")


def _infer_user_id(data: dict) -> str:
    """Firestore ドキュメントからユーザー ID を推定"""
    comments = data.get("comments", {})
    if comments:
        for comment_data in comments.values():
            if isinstance(comment_data, dict):
                author_id = comment_data.get("authorId")
                if author_id:
                    return author_id
    return "shared"


def _build_identity_key_map(supabase, records: list) -> dict:
    """
    Firestore docID → Supabase identity_key のマッピングを構築。
    docID = SHA256(identity_key)[:16] なので、逆引きはできない。
    代わりに Supabase の全 listings の identity_key を取得して
    SHA256 ハッシュで照合する。
    """
    import hashlib

    # Supabase から全 identity_key を取得
    all_keys = []
    offset = 0
    page_size = 1000
    while True:
        result = supabase.table("listings").select("identity_key").range(offset, offset + page_size - 1).execute()
        if not result.data:
            break
        all_keys.extend(row["identity_key"] for row in result.data)
        if len(result.data) < page_size:
            break
        offset += page_size

    # identity_key → docID のマップを構築
    doc_id_to_key = {}
    for key in all_keys:
        hash_hex = hashlib.sha256(key.encode()).hexdigest()[:16]
        doc_id_to_key[hash_hex] = key

    return doc_id_to_key


if __name__ == "__main__":
    migrate()
