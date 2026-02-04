"""
Notion API の薄いラッパー。
データベースのクエリ・ページ作成・ブロック追加を行う。
"""

import os
import re
import time
from typing import Any, Optional
from urllib.parse import quote

import requests

NOTION_API_BASE = "https://api.notion.com/v1"
# ブロック1つあたりの本文上限（Notion API）
NOTION_BLOCK_CONTENT_LIMIT = 2000
# ページ作成時に渡せる子ブロックの最大数
NOTION_PAGE_CHILDREN_LIMIT = 100


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


def _api_error_message(resp: requests.Response) -> str:
    """API エラー時のレスポンス本文からメッセージを抽出する。"""
    try:
        data = resp.json()
        msg = data.get("message", "")
        code = data.get("code", "")
        if code:
            return f"{code}: {msg}" if msg else code
        return msg or resp.text[:500]
    except Exception:
        return resp.text[:500] or str(resp.status_code)


def query_database_by_url(database_id: str, url: str) -> Optional[dict]:
    """
    データベースを URL で検索し、該当するページを1件返す。
    見つからなければ None。
    """
    # Notion のプロパティ名は「詳細」に合わせる（SUUMO/HOME'S の詳細URLを格納）
    last_err = ""
    for filter_key in ("url", "rich_text"):
        payload = {
            "filter": {"property": "詳細", filter_key: {"equals": url}},
            "page_size": 1,
        }
        resp = requests.post(
            f"{NOTION_API_BASE}/databases/{database_id}/query",
            headers=_headers(),
            json=payload,
            timeout=30,
        )
        if resp.status_code == 200:
            data = resp.json()
            results = data.get("results", [])
            return results[0] if results else None
        last_err = _api_error_message(resp)
        if resp.status_code != 400:
            raise ValueError(f"Notion API {resp.status_code}: {last_err}")
    raise ValueError(f"Notion API 400 Bad Request: {last_err}")


def _select_prop(v: Any, default: str = "") -> dict:
    """
    Select プロパティ用。値が空の場合は default を使う（ownership 必須用）。
    存在しない選択肢は Notion が新規作成、既存のものはそのまま選択（同じ名前の選択肢が2つ以上作られない）。
    """
    s = (v is not None and str(v).strip()) or default
    s = s[:100] if s else ""
    if not s:
        return {"select": None}
    return {"select": {"name": s}}


def _status_prop(sold_out: bool) -> dict:
    """
    ステータス用。sold_out=True なら「売り切れ」、False なら「販売中」。
    選択肢は Notion 側で事前に「販売中」「売り切れ」を用意しておくこと。
    """
    name = "売り切れ" if sold_out else "販売中"
    return {"status": {"name": name}}


def _ward_kanji_from_address(address: str) -> str:
    """住所から区名（漢字）を抽出。例: 東京都文京区千石4-2-2 → 文京区。"""
    if not address or not address.strip():
        return ""
    m = re.search(r"(?:東京都)?([一-龥ぁ-んァ-ン]+区)", address.strip())
    return m.group(1) if m else ""


def listing_to_properties(
    r: dict[str, Any],
    *,
    sold_out: bool = False,
    m3_min: Optional[int] = None,
    pg_min: Optional[int] = None,
) -> dict[str, Any]:
    """
    スクレイピング結果の1件を Notion のページプロパティに変換する。
    Notion のカラム名に合わせる: 名前, 詳細, 住所, Google Map, 価格（万円）, 区, 販売状況, ...
    区は住所から漢字で抽出。路線・駅・間取りは Notion 側の型に合わせる。
    """
    name = (r.get("name") or "").strip() or "(無題)"
    address = (r.get("address") or "").strip()
    google_map_url = (
        f"https://www.google.com/maps/search/?api=1&query={quote(address)}" if address else None
    )
    ward_kanji = _ward_kanji_from_address(address)
    props = {
        "名前": {"title": [{"text": {"content": name[:2000]}}]},
        "詳細": _url_prop(r.get("url")),
        "住所": _rich_text_prop(r.get("address")),
        "Google Map": _url_prop(google_map_url),
        "価格（万円）": _number_prop(r.get("price_man")),
        "区": _select_prop(ward_kanji),
        "販売状況": _status_prop(sold_out),
        "専有面積（㎡）": _number_prop(r.get("area_m2")),
        "徒歩（分）": _number_prop(r.get("walk_min")),
        "所在階": _number_prop(r.get("floor_position")),
        "権利形態": _select_prop(r.get("ownership"), default="不明"),
        "築年数": _number_prop(r.get("built_year")),
        "総戸数": _number_prop(r.get("total_units")),
        "路線・駅": _rich_text_prop(r.get("station_line")),
        "間取り": _select_prop(r.get("layout")),
        "階建": _number_prop(r.get("floor_total")),
        "M3": _number_prop(m3_min),
        "PG": _number_prop(pg_min),
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
    """データベースに新規ページを作成する。子ブロックは最大100個まで（超えた分は append_blocks で追加すること）。"""
    body = {
        "parent": {"database_id": database_id},
        "properties": properties,
    }
    if children:
        body["children"] = children[:NOTION_PAGE_CHILDREN_LIMIT]
    resp = requests.post(
        f"{NOTION_API_BASE}/pages",
        headers=_headers(),
        json=body,
        timeout=30,
    )
    if not resp.ok:
        raise ValueError(f"Notion API {resp.status_code}: {_api_error_message(resp)}")
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


def make_embed_block(url: str) -> dict:
    """
    Embed ブロックを作成。URL のウェブページを Notion 内に埋め込み表示する（Web Clipper 風）。
    Notion は Iframely で対応ドメインならプレビューを表示する。未対応の場合はリンクとして表示される。
    """
    return {"object": "block", "type": "embed", "embed": {"url": url}}


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


def _normalize_html(html: str) -> str:
    """改行・空白をまとめてブロック数を減らす。連続改行を1つに、連続スペースを1つに。"""
    s = re.sub(r"\n{2,}", "\n", html)
    s = re.sub(r"[ \t]{2,}", " ", s)
    return s


def make_code_blocks(html: str, chunk_size: int = NOTION_BLOCK_CONTENT_LIMIT) -> list[dict]:
    """
    HTML 文字列を Notion のコードブロックのリストに分割する。
    改行・空白は正規化してから分割。1ブロックあたり chunk_size 文字まで。
    """
    html = _normalize_html(html)
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
