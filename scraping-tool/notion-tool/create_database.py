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
            "url": {"name": "url", "type": "url", "url": {}},
            "price_man": {"name": "price_man", "type": "number", "number": {"format": "number"}},
            "address": {"name": "address", "type": "rich_text", "rich_text": {}},
            "station_line": {"name": "station_line", "type": "select", "select": {"options": []}},
            "walk_min": {"name": "walk_min", "type": "number", "number": {"format": "number"}},
            "area_m2": {"name": "area_m2", "type": "number", "number": {"format": "number"}},
            "layout": {"name": "layout", "type": "rich_text", "rich_text": {}},
            "built_year": {"name": "built_year", "type": "number", "number": {"format": "number"}},
            "total_units": {"name": "total_units", "type": "number", "number": {"format": "number"}},
            "floor_position": {"name": "floor_position", "type": "number", "number": {"format": "number"}},
            "floor_total": {"name": "floor_total", "type": "number", "number": {"format": "number"}},
            "list_ward_roman": {"name": "list_ward_roman", "type": "select", "select": {"options": []}},
            "ownership": {"name": "ownership", "type": "select", "select": {"options": [{"name": "不明", "color": "gray"}]}},
            "ステータス": {"name": "ステータス", "type": "status", "status": {"options": [{"name": "販売中", "color": "green"}, {"name": "売り切れ", "color": "gray"}]}},
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
