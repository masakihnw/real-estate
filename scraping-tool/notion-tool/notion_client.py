"""
Notion API の薄いラッパー。
データベースのクエリ・ページ作成・ブロック追加を行う。
"""

import os
import time
from typing import Any, Optional

import requests

NOTION_API_BASE = "https://api.notion.com/v1"
# ブロック1つあたりの本文上限（Notion API）
NOTION_BLOCK_CONTENT_LIMIT = 2000


def _headers() -> dict[str, str]:
    token = os.environ.get("NOTION_TOKEN", "").strip()
    if not token:
        raise ValueError("NOTION_TOKEN が設定されていません")
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Notion-Version": "2022-06-28",
    }


def _rich_text(content: str) -> list[dict]:
    """Notion の rich_text 配列。2000文字を超える場合は複数に分割。"""
    if not content:
        return [{"text": {"content": ""}}]
    chunks: list[dict] = []
    rest = content
    while rest:
        chunk = rest[:NOTION_BLOCK_CONTENT_LIMIT]
        rest = rest[NOTION_BLOCK_CONTENT_LIMIT:]
        chunks.append({"text": {"content": chunk}})
    return chunks


def get_database_select_options(database_id: str) -> dict[str, set[str]]:
    """
    データベースの Select / Status プロパティごとに、既存の選択肢名の集合を返す。
    既に入力済みのものだけを選択し、新規の選択肢は作成しないために使用する。
    """
    resp = requests.get(
        f"{NOTION_API_BASE}/databases/{database_id}",
        headers=_headers(),
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    result: dict[str, set[str]] = {}
    for prop_name, prop_schema in (data.get("properties") or {}).items():
        ptype = prop_schema.get("type")
        options: list[dict] = []
        if ptype == "select":
            options = prop_schema.get("select", {}).get("options") or []
        elif ptype == "status":
            options = prop_schema.get("status", {}).get("options") or []
        if options:
            result[prop_name] = {opt.get("name", "").strip() for opt in options if opt.get("name")}
    return result


def query_database_by_url(database_id: str, url: str) -> Optional[dict]:
    """
    データベースを URL で検索し、該当するページを1件返す。
    見つからなければ None。
    """
    # URL プロパティは API によっては rich_text と同様にフィルタする
    payload = {
        "filter": {"property": "url", "rich_text": {"equals": url}},
        "page_size": 1,
    }
    resp = requests.post(
        f"{NOTION_API_BASE}/databases/{database_id}/query",
        headers=_headers(),
        json=payload,
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    results = data.get("results", [])
    return results[0] if results else None


def _select_prop(v: Any, default: str = "", *, allowed: Optional[set[str]] = None) -> dict:
    """
    Select プロパティ用。値が空の場合は default を使う（ownership 必須用）。
    allowed が渡された場合、その集合に含まれる名前だけを設定し、含まれない場合は新規作成せず None を返す。
    """
    s = (v is not None and str(v).strip()) or default
    s = s[:100] if s else ""
    if allowed is not None and s and s not in allowed:
        return {"select": None}
    if not s:
        return {"select": None}
    return {"select": {"name": s}}


def _status_prop(sold_out: bool, *, allowed: Optional[set[str]] = None) -> dict:
    """
    ステータス用。sold_out=True なら「売り切れ」、False なら「販売中」。
    allowed が渡された場合はその集合に含まれる場合のみ設定する。
    """
    name = "売り切れ" if sold_out else "販売中"
    if allowed is not None and name not in allowed:
        return {"status": None}
    return {"status": {"name": name}}


def listing_to_properties(
    r: dict[str, Any],
    *,
    sold_out: bool = False,
    allowed_select_options: Optional[dict[str, set[str]]] = None,
) -> dict[str, Any]:
    """
    スクレイピング結果の1件を Notion のページプロパティに変換する。
    カラム名はそのままプロパティ名として使用（名前のみ title 扱い）。
    sold_out=True のときはステータスを「売り切れ」、False のときは「販売中」に設定する。
    allowed_select_options を渡すと、Select / Status は既存の選択肢に含まれる場合のみ設定し、新規の選択肢は作成しない。
    """
    name = (r.get("name") or "").strip() or "(無題)"
    opts = allowed_select_options or {}
    props = {
        "名前": {"title": [{"text": {"content": name[:2000]}}]},
        "url": _url_prop(r.get("url")),
        "price_man": _number_prop(r.get("price_man")),
        "address": _rich_text_prop(r.get("address")),
        "station_line": _select_prop(r.get("station_line"), allowed=opts.get("station_line")),
        "walk_min": _number_prop(r.get("walk_min")),
        "area_m2": _number_prop(r.get("area_m2")),
        "layout": _rich_text_prop(r.get("layout")),
        "built_year": _number_prop(r.get("built_year")),
        "total_units": _number_prop(r.get("total_units")),
        "floor_position": _number_prop(r.get("floor_position")),
        "floor_total": _number_prop(r.get("floor_total")),
        "list_ward_roman": _select_prop(r.get("list_ward_roman"), allowed=opts.get("list_ward_roman")),
        "ownership": _select_prop(r.get("ownership"), default="不明", allowed=opts.get("ownership")),
        "ステータス": _status_prop(sold_out, allowed=opts.get("ステータス")),
    }
    return props


def _url_prop(v: Any) -> dict:
    if v is None or (isinstance(v, str) and not v.strip()):
        return {"url": None}
    return {"url": str(v).strip()}


def _number_prop(v: Any) -> dict:
    if v is None:
        return {"number": None}
    try:
        return {"number": int(float(v))}
    except (TypeError, ValueError):
        return {"number": None}


def _rich_text_prop(v: Any) -> dict:
    if v is None:
        return {"rich_text": []}
    s = str(v).strip()[:2000]
    if not s:
        return {"rich_text": []}
    return {"rich_text": [{"text": {"content": s}}]}


def create_page(
    database_id: str,
    properties: dict[str, Any],
    children: Optional[list[dict]] = None,
) -> dict:
    """データベースに新規ページを作成する。"""
    body = {
        "parent": {"database_id": database_id},
        "properties": properties,
    }
    if children:
        body["children"] = children
    resp = requests.post(
        f"{NOTION_API_BASE}/pages",
        headers=_headers(),
        json=body,
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def append_blocks(page_id: str, children: list[dict]) -> None:
    """既存ページの末尾にブロックを追加する。"""
    # Notion は一度に最大100ブロックまで
    for i in range(0, len(children), 100):
        chunk = children[i : i + 100]
        resp = requests.patch(
            f"{NOTION_API_BASE}/blocks/{page_id}/children",
            headers=_headers(),
            json={"children": chunk},
            timeout=30,
        )
        resp.raise_for_status()
        if i + 100 < len(children):
            time.sleep(0.35)  # レート制限を考慮


def update_page_properties(page_id: str, properties: dict[str, Any]) -> None:
    """ページのプロパティのみ更新する。"""
    resp = requests.patch(
        f"{NOTION_API_BASE}/pages/{page_id}",
        headers=_headers(),
        json={"properties": properties},
        timeout=30,
    )
    resp.raise_for_status()


def make_bookmark_block(url: str) -> dict:
    """ブックマークブロック（リンクプレビュー）を作成。"""
    return {"object": "block", "type": "bookmark", "bookmark": {"url": url}}


def make_heading2_block(text: str) -> dict:
    """見出し2ブロック。"""
    return {
        "object": "block",
        "type": "heading_2",
        "heading_2": {"rich_text": [{"text": {"content": text[:2000]}}]},
    }


def make_image_block(image_url: str) -> dict:
    """外部 URL の画像ブロックを作成。"""
    return {
        "object": "block",
        "type": "image",
        "image": {"type": "external", "external": {"url": image_url}},
    }


def make_code_blocks(html: str, chunk_size: int = NOTION_BLOCK_CONTENT_LIMIT) -> list[dict]:
    """
    HTML 文字列を Notion のコードブロックのリストに分割する。
    1ブロックあたり chunk_size 文字まで。
    """
    blocks = []
    rest = html
    while rest:
        chunk = rest[:chunk_size]
        rest = rest[chunk_size:]
        blocks.append({
            "object": "block",
            "type": "code",
            "code": {
                "rich_text": [{"text": {"content": chunk}}],
                "language": "plain text",
            },
        })
    return blocks
