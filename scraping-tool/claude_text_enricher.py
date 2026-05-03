#!/usr/bin/env python3
"""
Claude API による物件説明文の構造化抽出モジュール。

物件の説明文・備考・feature_tags から以下を抽出:
- リノベーション履歴
- 管理状態・修繕積立金の評価
- 設備ハイライト
- 売却理由のシグナル
- ネガティブ要因
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Optional

from logger import get_logger

logger = get_logger(__name__)

SYSTEM_PROMPT = """あなたは不動産物件情報の構造化抽出エキスパートです。
物件の説明文・特徴タグから、投資判断に重要な情報を抽出してください。

JSON形式で回答:
{
  "renovation_history": "2023年フルリノベーション済（キッチン・浴室・床暖房新設）",
  "management_quality": "管理良好",
  "equipment_highlights": ["食洗機", "床暖房", "ディスポーザー", "宅配ボックス"],
  "seller_motivation": "転勤",
  "negative_factors": ["1階", "北向き"],
  "notable_points": "角部屋・両面バルコニー"
}

各フィールドの説明:
- renovation_history: リノベーション・リフォームの内容と時期。なければ null
- management_quality: 管理状態の評価（"管理優良"/"管理良好"/"管理普通"/"管理注意"/"不明"）
- equipment_highlights: 投資価値を高める設備（一般的なもの（エアコ��等）は除外）
- seller_motivation: 売却理由の推測（"転勤"/"住み替え"/"相続"/"投資売却"/"不明"）。明示されていなければ null
- negative_factors: 価格に影響するマイナス要因。なけれ���空配列
- notable_points: その他の注目ポイント。なければ null

情報がない場合は null や空配列を返してください。推測で埋めないでください。"""


def _build_listing_text(listing: dict) -> str:
    """物件から分析対象テキストを構築。"""
    parts = []
    if listing.get("name"):
        parts.append(f"物件名: {listing['name']}")
    if listing.get("address"):
        parts.append(f"住所: {listing['address']}")
    if listing.get("layout"):
        parts.append(f"間取り: {listing['layout']}")
    if listing.get("area_m2"):
        parts.append(f"面積: {listing['area_m2']}m²")
    if listing.get("built_year"):
        parts.append(f"築年: {listing['built_year']}年")
    if listing.get("floor_position"):
        parts.append(f"階数: {listing['floor_position']}階/{listing.get('floor_total', '?')}階建て")
    if listing.get("total_units"):
        parts.append(f"総戸数: {listing['total_units']}戸")
    if listing.get("management_fee"):
        parts.append(f"管理費: {listing['management_fee']}円/月")
    if listing.get("repair_reserve_fund"):
        parts.append(f"修繕積立金: {listing['repair_reserve_fund']}円/月")

    feature_tags = listing.get("feature_tags") or []
    if feature_tags:
        parts.append(f"特徴タグ: {', '.join(feature_tags)}")

    remarks = listing.get("remarks") or listing.get("description") or ""
    if remarks:
        parts.append(f"備考: {remarks[:500]}")

    equipment = listing.get("equipment") or ""
    if equipment:
        parts.append(f"設備: {equipment[:300]}")

    return "\n".join(parts)


def enrich_text_features(listings: list[dict]) -> list[dict]:
    """物件説明文から構造化データを抽出。"""
    from claude_client import ClaudeClient, BatchRequest, DEFAULT_MODEL

    if not ClaudeClient.is_available():
        logger.warning("ANTHROPIC_API_KEY 未設定: テキスト抽出スキップ")
        return listings

    client = ClaudeClient()
    requests: list[BatchRequest] = []
    request_indices: list[int] = []

    for i, listing in enumerate(listings):
        if listing.get("extracted_features"):
            continue

        text = _build_listing_text(listing)
        if len(text) < 50:
            continue

        cache_input = {"text": text[:500]}
        cached = client.get_cached("text_features", cache_input)
        if cached:
            listing["extracted_features"] = cached
            continue

        requests.append(BatchRequest(
            custom_id=f"text_{i}",
            messages=[{"role": "user", "content": text}],
            system=SYSTEM_PROMPT,
            model=DEFAULT_MODEL,
            max_tokens=512,
        ))
        request_indices.append(i)

    if not requests:
        logger.info("テキスト抽出: 全てキャッシュ済みまたは対象なし")
        return listings

    logger.info("テキスト抽出: %d件を送信", len(requests))
    batch_results = client.send_messages(requests)

    success_count = 0
    for br in batch_results:
        idx_str = br.custom_id.replace("text_", "")
        try:
            i = int(idx_str)
        except ValueError:
            continue

        if br.error:
            logger.warning("テキスト抽出エラー (listing %d): %s", i, br.error)
            continue

        parsed = client.parse_json_response(br.content)
        if parsed:
            listings[i]["extracted_features"] = parsed
            text = _build_listing_text(listings[i])
            client.set_cached("text_features", {"text": text[:500]}, parsed,
                              model=DEFAULT_MODEL,
                              input_tokens=br.input_tokens,
                              output_tokens=br.output_tokens)
            success_count += 1

    logger.info("テキスト抽出完了: %d/%d件成功", success_count, len(requests))
    return listings


def main():
    parser = argparse.ArgumentParser(description="Claude テキスト��造化抽出")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    with open(args.input, encoding="utf-8") as f:
        listings = json.load(f)

    listings = enrich_text_features(listings)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
