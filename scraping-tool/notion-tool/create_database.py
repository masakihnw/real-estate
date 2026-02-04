#!/usr/bin/env python3
"""
Notion に「物件一覧」用データベースを自動作成する。
親ページ ID とトークンが必要。作成後、NOTION_DATABASE_ID に返却された ID を設定する。
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import requests

NOTION_API_BASE = "https://api.notion.com/v1"


def _headers() -> dict[str, str]:
    token = os.environ.get("NOTION_TOKEN", "").strip()
    if not token:
        print("NOTION_TOKEN を設定してください", file=sys.stderr)
        sys.exit(1)
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Notion-Version": "2022-06-28",
    }


def main() -> None:
    parent_id = (os.environ.get("NOTION_PARENT_PAGE_ID") or "").strip().replace("-", "")
    if not parent_id:
        print("NOTION_PARENT_PAGE_ID（データベースを置く親ページの ID）を設定してください", file=sys.stderr)
        sys.exit(1)

    body = {
        "parent": {"type": "page_id", "page_id": parent_id},
        "title": [{"type": "text", "text": {"content": "物件一覧"}}],
        "properties": {
            "名前": {"name": "名前", "type": "title", "title": {}},
            "詳細": {"name": "詳細", "type": "url", "url": {}},
            "住所": {"name": "住所", "type": "rich_text", "rich_text": {}},
            "Google Map": {"name": "Google Map", "type": "url", "url": {}},
            "価格（万円）": {"name": "価格（万円）", "type": "number", "number": {"format": "number"}},
            "区": {"name": "区", "type": "select", "select": {"options": []}},
            "専有面積（㎡）": {"name": "専有面積（㎡）", "type": "number", "number": {"format": "number"}},
            "徒歩（分）": {"name": "徒歩（分）", "type": "number", "number": {"format": "number"}},
            "所在階": {"name": "所在階", "type": "number", "number": {"format": "number"}},
            "権利形態": {"name": "権利形態", "type": "select", "select": {"options": [{"name": "不明", "color": "gray"}]}},
            "築年数": {"name": "築年数", "type": "number", "number": {"format": "number"}},
            "総戸数": {"name": "総戸数", "type": "number", "number": {"format": "number"}},
            "路線・駅": {"name": "路線・駅", "type": "rich_text", "rich_text": {}},
            "間取り": {"name": "間取り", "type": "select", "select": {"options": []}},
            "階建": {"name": "階建", "type": "number", "number": {"format": "number"}},
            "M3": {"name": "M3", "type": "number", "number": {"format": "number"}},
            "PG": {"name": "PG", "type": "number", "number": {"format": "number"}},
        },
    }

    resp = requests.post(
        f"{NOTION_API_BASE}/databases",
        headers=_headers(),
        json=body,
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    db_id = data.get("id", "")
    print(f"データベースを作成しました。ID: {db_id}", file=sys.stderr)
    print(f"NOTION_DATABASE_ID={db_id}")


if __name__ == "__main__":
    main()
