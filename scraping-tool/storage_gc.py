"""listing-images の不要画像 GC の純粋ロジック。

副作用（API 呼び出し・ファイル IO）を持たない判定関数のみを置く。
実行系は scripts/storage_image_gc.py。

削除対象の定義:
  - 孤児: enrichments のどの行からも参照されていないオブジェクト
  - 掲載終了のみ参照: is_active=false の物件からしか参照されていないオブジェクト
"""

from __future__ import annotations

from typing import Any, Optional

from image_storage import extract_object_name


def collect_image_urls(row: dict[str, Any]) -> list[str]:
    """enrichments 1行から画像 URL をすべて集める（外部 URL も含む）。

    iOS 詳細画面は image_categories を主ソースに使うため、ここに含めないと
    GC が「未参照」と誤判定して詳細用画像を削除してしまう（過去に発生）。
    """
    urls: list[str] = []
    for img in row.get("suumo_images") or []:
        if isinstance(img, dict) and isinstance(img.get("url"), str):
            urls.append(img["url"])
    for img in row.get("image_categories") or []:
        if isinstance(img, dict) and isinstance(img.get("url"), str):
            urls.append(img["url"])
    for url in row.get("floor_plan_images") or []:
        if isinstance(url, str):
            urls.append(url)
    thumb = row.get("best_thumbnail_url")
    if isinstance(thumb, str):
        urls.append(thumb)
    return urls


def collect_refs(
    enrichment_rows: list[dict[str, Any]],
    active_listing_ids: set[int],
) -> tuple[set[str], set[str]]:
    """参照されているオブジェクト名を (active参照, 全参照) で返す。"""
    active_refs: set[str] = set()
    all_refs: set[str] = set()
    for row in enrichment_rows:
        names = {extract_object_name(u) for u in collect_image_urls(row)}
        names.discard(None)
        all_refs |= names  # type: ignore[arg-type]
        if row.get("listing_id") in active_listing_ids:
            active_refs |= names  # type: ignore[arg-type]
    return active_refs, all_refs


def select_deletable(
    object_names: set[str],
    active_refs: set[str],
) -> set[str]:
    """掲載中物件から参照されていないオブジェクトを削除対象として返す。"""
    return object_names - active_refs


def prune_manifest(
    manifest: dict[str, str],
    deleted_names: set[str],
) -> tuple[dict[str, str], int]:
    """削除済みオブジェクトを指すマニフェストエントリを除去する。

    エントリを残すと、再掲載時に「アップロード済み」と誤判定されて
    存在しない URL が配布されるため、剪定して再アップロードを強制する。
    Returns: (新しいマニフェスト, 除去件数)
    """
    pruned = {
        orig: stored
        for orig, stored in manifest.items()
        if extract_object_name(stored) not in deleted_names
    }
    return pruned, len(manifest) - len(pruned)


def scrub_enrichment_row(
    row: dict[str, Any],
    deleted_names: set[str],
) -> Optional[dict[str, Any]]:
    """削除済みオブジェクトへの参照を enrichments 行から取り除く。

    変更が必要な場合のみ update payload（変更フィールドだけ）を返す。
    外部 URL や削除されていないストレージ URL はそのまま残す。
    """

    def _deleted(url: Any) -> bool:
        return isinstance(url, str) and extract_object_name(url) in deleted_names

    payload: dict[str, Any] = {}

    suumo = row.get("suumo_images")
    if isinstance(suumo, list):
        kept = [
            img for img in suumo
            if not (isinstance(img, dict) and _deleted(img.get("url")))
        ]
        if len(kept) != len(suumo):
            payload["suumo_images"] = kept

    cats = row.get("image_categories")
    if isinstance(cats, list):
        kept = [
            img for img in cats
            if not (isinstance(img, dict) and _deleted(img.get("url")))
        ]
        if len(kept) != len(cats):
            payload["image_categories"] = kept

    floor = row.get("floor_plan_images")
    if isinstance(floor, list):
        kept = [url for url in floor if not _deleted(url)]
        if len(kept) != len(floor):
            payload["floor_plan_images"] = kept

    if _deleted(row.get("best_thumbnail_url")):
        payload["best_thumbnail_url"] = None

    return payload or None
