#!/usr/bin/env python3
"""
Claude Vision API による画像分析モジュール。

各物件画像に対して:
- ジャンク判定（広告/バナー/アイコンを除外）
- カテゴリ分類（exterior/interior/water/floor_plan/view/common_area）
- 品質スコア（0.0-1.0）
- サムネイル適性スコア（0.0-1.0）

既存のラベルベースフィルタ（_REHOUSE_JUNK_LABELS 等）をフォールバックとして残しつつ、
Claude Vision でより正確な分類を行う。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Optional

from logger import get_logger

logger = get_logger(__name__)

SYSTEM_PROMPT = """あなたは不動産物件画像の分類エキスパートです。
画像を分析し、以下のJSON形式で回答してください。

{
  "is_junk": false,
  "category": "interior",
  "quality_score": 0.8,
  "thumbnail_score": 0.7,
  "brief_description": "明るいリビングダイニング"
}

カテゴリ:
- "exterior": 建物外観（正面・エントランス含む）
- "interior": 室内（リビング・居室・キッチン）
- "water": 水回り（浴室・トイレ・洗面所）
- "floor_plan": 間取り図
- "view": 眺望・バルコニーからの景色
- "common_area": 共用部（エントランスホール・庭園・ジム等）
- "surroundings": 周辺環境（駅・商業施設・公園）
- "junk": 広告・バナー・アイコン・ロゴ・地図のみ

is_junk を true にすべき画像:
- 不動産ポータルの広告バナー・キャンペーン画像
- 「ペット可」「南向き」等のアイコン/ラベル画像
- 会社ロゴのみの画像
- 物件と無関係な人物写真・イラスト
- QRコードのみ

quality_score: 画像の鮮明さ・情報量（0=ぼやけ/暗い、1=鮮明/明るい）
thumbnail_score: 物件カードの代表画像としての適性（0=不適、1=最適）
  高い: 外観全体・明るいリビング  低い: 間取り図・クローゼット内部"""

IMAGE_BATCH_SIZE = 10


def _build_image_content(url: str) -> list[dict]:
    """画像URL から messages content を構築。"""
    return [
        {"type": "image", "source": {"type": "url", "url": url}},
        {"type": "text", "text": "この画像を分類してください。"},
    ]


def analyze_listing_images(listings: list[dict]) -> list[dict]:
    """全物件の画像を分析し、分類結果を付与する。"""
    from claude_client import ClaudeClient, BatchRequest, DEFAULT_MODEL

    if not ClaudeClient.is_available():
        logger.warning("ANTHROPIC_API_KEY 未設定: 画像分析スキップ")
        return listings

    client = ClaudeClient()
    requests: list[BatchRequest] = []
    request_map: list[tuple[int, int]] = []  # (listing_idx, image_idx)

    for li, listing in enumerate(listings):
        images = listing.get("suumo_images") or []
        for ii, img in enumerate(images):
            url = img.get("url", "")
            if not url:
                continue
            if img.get("claude_category"):
                continue

            cache_input = {"url": url}
            cached = client.get_cached("image", cache_input)
            if cached:
                img["claude_category"] = cached.get("category", "")
                img["claude_quality"] = cached.get("quality_score", 0.5)
                img["claude_thumbnail_score"] = cached.get("thumbnail_score", 0.5)
                img["is_junk"] = cached.get("is_junk", False)
                img["claude_description"] = cached.get("brief_description", "")
                continue

            try:
                requests.append(BatchRequest(
                    custom_id=f"img_{li}_{ii}",
                    messages=[{"role": "user", "content": _build_image_content(url)}],
                    system=SYSTEM_PROMPT,
                    model=DEFAULT_MODEL,
                    max_tokens=256,
                ))
                request_map.append((li, ii))
            except Exception as e:
                logger.warning("画像リクエスト構築失敗 (%s): %s", url[:60], e)

    if not requests:
        logger.info("画像分析: 全てキャッシュ済み")
        _apply_best_thumbnails(listings)
        return listings

    logger.info("画像分析: %d枚を送信（キャッシュ外）", len(requests))

    all_results = []
    for batch_start in range(0, len(requests), IMAGE_BATCH_SIZE):
        batch = requests[batch_start:batch_start + IMAGE_BATCH_SIZE]
        results = client.send_messages(batch, use_batch=(len(requests) >= 5))
        all_results.extend(results)

    for br in all_results:
        parts = br.custom_id.split("_")
        if len(parts) != 3:
            continue
        try:
            li, ii = int(parts[1]), int(parts[2])
        except ValueError:
            continue

        img = listings[li].get("suumo_images", [])[ii] if ii < len(listings[li].get("suumo_images", [])) else None
        if img is None:
            continue

        if br.error:
            logger.warning("画像分析エラー (%s): %s", img.get("url", "")[:40], br.error)
            continue

        parsed = client.parse_json_response(br.content)
        if parsed:
            img["claude_category"] = parsed.get("category", "")
            img["claude_quality"] = parsed.get("quality_score", 0.5)
            img["claude_thumbnail_score"] = parsed.get("thumbnail_score", 0.5)
            img["is_junk"] = parsed.get("is_junk", False)
            img["claude_description"] = parsed.get("brief_description", "")

            client.set_cached("image", {"url": img["url"]}, parsed,
                              model=DEFAULT_MODEL,
                              input_tokens=br.input_tokens,
                              output_tokens=br.output_tokens)

    _apply_best_thumbnails(listings)
    _build_image_categories(listings)

    junk_count = sum(
        1 for l in listings
        for img in (l.get("suumo_images") or [])
        if img.get("is_junk")
    )
    logger.info("画像分析完了: ジャンク検出 %d枚", junk_count)

    return listings


def _apply_best_thumbnails(listings: list[dict]) -> None:
    """各物件のベストサムネイルを選定。"""
    for listing in listings:
        images = listing.get("suumo_images") or []
        valid_images = [img for img in images if not img.get("is_junk")]
        if not valid_images:
            continue
        best = max(valid_images, key=lambda img: img.get("claude_thumbnail_score", 0.0))
        if best.get("claude_thumbnail_score", 0) > 0:
            listing["best_thumbnail_url"] = best["url"]


def _build_image_categories(listings: list[dict]) -> None:
    """カテゴリ分類済み画像を構造化フィールドに格納。"""
    for listing in listings:
        images = listing.get("suumo_images") or []
        categories: dict[str, list[dict]] = {}
        for img in images:
            if img.get("is_junk"):
                continue
            cat = img.get("claude_category", "other")
            if cat not in categories:
                categories[cat] = []
            categories[cat].append({
                "url": img.get("url", ""),
                "label": img.get("label", ""),
                "quality": img.get("claude_quality", 0.5),
                "description": img.get("claude_description", ""),
            })
        for cat_images in categories.values():
            cat_images.sort(key=lambda x: x.get("quality", 0), reverse=True)

        if categories:
            listing["image_categories"] = categories


def main():
    parser = argparse.ArgumentParser(description="Claude 画像分析")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    with open(args.input, encoding="utf-8") as f:
        listings = json.load(f)

    listings = analyze_listing_images(listings)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
