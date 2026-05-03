#!/usr/bin/env python3
"""
Claude API による投資判断サマリー生成モジュール。

全スコア・enrichmentデータを統合し、各物件に対して:
- investment_summary: 1-2文の自然言語サマリー
- highlight_badge: 3-5文字のバッジテキスト

コスト最適化: デフォルトでは「有望物件」のみ Claude API に送信する。
フィルタ条件を満たさない物件はスキップされ、サマリーは生成されない。
--skip-filter オプションで全件処理も可能。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Optional

from logger import get_logger

logger = get_logger(__name__)

# ─────────────────────── フィルタ閾値（有望物件の判定） ───────────────────────
# いずれか1つでも満たせば「有望」と判定する（OR 条件）
# listing_score: 総合投資スコア（0-100）。55以上で上位〜中上位
FILTER_LISTING_SCORE_MIN = 55
# ss_profit_pct: 住まいサーフィン儲かる確率（0-100%）。50%以上で利益期待
FILTER_SS_PROFIT_PCT_MIN = 50
# asset_rank: 資産性ランク。S/A/B が有望（C は除外）
FILTER_ASSET_RANKS_PROMISING = {"S", "A", "B"}
# price_fairness_score: 価格妥当性スコア。60以上は割安寄り
FILTER_PRICE_FAIRNESS_MIN = 60


def _is_promising(listing: dict) -> bool:
    """
    物件が「有望」かどうかを判定する。
    以下のいずれか1つでも満たせば有望と判定（OR 条件）:
    1. listing_score >= FILTER_LISTING_SCORE_MIN
    2. ss_profit_pct >= FILTER_SS_PROFIT_PCT_MIN
    3. asset_rank が S/A/B のいずれか
    4. price_fairness_score >= FILTER_PRICE_FAIRNESS_MIN

    スコアデータが一切ない物件は判定不能のためスキップ（有望でないと扱う）。
    """
    listing_score = listing.get("listing_score")
    if listing_score is not None and listing_score >= FILTER_LISTING_SCORE_MIN:
        return True

    ss_profit = listing.get("ss_profit_pct")
    if ss_profit is not None and ss_profit >= FILTER_SS_PROFIT_PCT_MIN:
        return True

    asset_rank = listing.get("asset_rank")
    if asset_rank and asset_rank in FILTER_ASSET_RANKS_PROMISING:
        return True

    price_fairness = listing.get("price_fairness_score")
    if price_fairness is not None and price_fairness >= FILTER_PRICE_FAIRNESS_MIN:
        return True

    return False

SYSTEM_PROMPT = """あなたは不動産投資アドバイザーです。
物件のスコアと特徴から、投資判断サマリーを生成してください。

JSON形式で回答:
{
  "summary": "駅2分の築浅タワマン。含み益S判定かつ流動性高く、10年後の資産価値維持が期待できる好物件。",
  "highlight_badge": "築浅×駅2分",
  "key_strengths": ["駅近", "含み益S", "管理良好"],
  "key_risks": ["価格帯が高い"]
}

ルール:
- summary: 1-2文。具体的な数値や判定結果を含め、「なぜ良いか/悪いか」を伝える
- highlight_badge: 物件リストで一目で分かる3-5文字のキーフレーズ。例: "築浅×駅2分", "含み益S", "値下げ注目", "割安判定", "再開発エリア"
- key_strengths: 主要な強み（3個以内）
- key_risks: 主要なリスク（3個以内、なければ空配列）
- 客観的事実に基づき、投資初心者にも分かりやすい日本語で"""


def _build_score_context(listing: dict) -> str:
    """物件のスコア情報を整理してテキスト化。"""
    parts = []
    parts.append(f"物件名: {listing.get('name', '不明')}")
    parts.append(f"価格: {listing.get('price_man', '?')}万円")
    parts.append(f"面積: {listing.get('area_m2', '?')}m²")
    parts.append(f"間取り: {listing.get('layout', '?')}")
    parts.append(f"築年: {listing.get('built_year', '?')}年")
    parts.append(f"徒歩: {listing.get('walk_min', '?')}分")
    parts.append(f"総戸数: {listing.get('total_units', '?')}戸")

    if listing.get("listing_score") is not None:
        parts.append(f"総合投資スコア: {listing['listing_score']}/100")
    if listing.get("price_fairness_score") is not None:
        parts.append(f"価格妥当性: {listing['price_fairness_score']}/100 (50=適正, 高い=割安)")
    if listing.get("resale_liquidity_score") is not None:
        parts.append(f"再販流動性: {listing['resale_liquidity_score']}/100")
    if listing.get("asset_rank"):
        parts.append(f"資産ランク: {listing['asset_rank']}")

    if listing.get("ss_value_judgment"):
        parts.append(f"住まいサーフィン評価: {listing['ss_value_judgment']}")
    if listing.get("ss_appreciation_rate") is not None:
        parts.append(f"値上がり率: {listing['ss_appreciation_rate']}%")

    hazard = listing.get("hazard_info")
    if hazard:
        if isinstance(hazard, str):
            try:
                hazard = json.loads(hazard)
            except (json.JSONDecodeError, TypeError):
                hazard = None
        if hazard and isinstance(hazard, dict):
            risk_level = hazard.get("overall_risk", "")
            if risk_level:
                parts.append(f"災害リスク: {risk_level}")

    price_history = listing.get("price_history")
    if price_history:
        if isinstance(price_history, str):
            try:
                ph = json.loads(price_history)
            except (json.JSONDecodeError, TypeError):
                ph = []
        else:
            ph = price_history
        if ph and len(ph) >= 2:
            latest = ph[-1].get("price_man", 0)
            first = ph[0].get("price_man", 0)
            if first > 0 and latest > 0:
                change_pct = (latest - first) / first * 100
                parts.append(f"価格推移: {change_pct:+.1f}%（初回掲載比）")

    features = listing.get("extracted_features")
    if features:
        if isinstance(features, str):
            try:
                features = json.loads(features)
            except (json.JSONDecodeError, TypeError):
                features = None
        if features and isinstance(features, dict):
            if features.get("renovation_history"):
                parts.append(f"リノベ: {features['renovation_history']}")
            if features.get("management_quality"):
                parts.append(f"管理: {features['management_quality']}")

    return "\n".join(parts)


def generate_investment_summaries(listings: list[dict], *, skip_filter: bool = False) -> list[dict]:
    """有望物件に投資サマリーを生成。

    Args:
        listings: 物件リスト（投資スコア注入済み）
        skip_filter: True の場合、フィルタリングを無効化して全件処理する
    """
    from claude_client import ClaudeClient, BatchRequest, DEFAULT_MODEL

    if not ClaudeClient.is_available():
        logger.warning("ANTHROPIC_API_KEY 未設定: サマリー生成スキップ")
        return listings

    # フィルタリング: 有望物件のみを対象とする
    if skip_filter:
        target_indices = list(range(len(listings)))
        logger.info("サマリー生成: フィルタ無効 (全%d件を対象)", len(listings))
    else:
        target_indices = [i for i, listing in enumerate(listings) if _is_promising(listing)]
        skipped_count = len(listings) - len(target_indices)
        logger.info(
            "サマリー生成: %d/%d件が有望物件 (%d件フィルタ除外)",
            len(target_indices), len(listings), skipped_count,
        )

    if not target_indices:
        logger.info("サマリー生成: 有望物件なし、スキップ")
        return listings

    client = ClaudeClient()
    requests: list[BatchRequest] = []
    request_indices: list[int] = []

    for i in target_indices:
        listing = listings[i]
        if listing.get("investment_summary") and listing.get("highlight_badge"):
            continue

        context = _build_score_context(listing)
        cache_key_data = {"context": context[:600]}
        cached = client.get_cached("investment_summary", cache_key_data)
        if cached:
            listing["investment_summary"] = cached.get("summary", "")
            listing["highlight_badge"] = cached.get("highlight_badge", "")
            listing["key_strengths"] = cached.get("key_strengths", [])
            listing["key_risks"] = cached.get("key_risks", [])
            continue

        requests.append(BatchRequest(
            custom_id=f"summary_{i}",
            messages=[{"role": "user", "content": context}],
            system=SYSTEM_PROMPT,
            model=DEFAULT_MODEL,
            max_tokens=384,
        ))
        request_indices.append(i)

    if not requests:
        logger.info("サマリー生成: 全てキャッシュ済み")
        return listings

    logger.info("サマリー生成: %d件を送信", len(requests))
    batch_results = client.send_messages(requests)

    success_count = 0
    for br in batch_results:
        idx_str = br.custom_id.replace("summary_", "")
        try:
            i = int(idx_str)
        except ValueError:
            continue

        if br.error:
            logger.warning("サマリー生成エラー (listing %d): %s", i, br.error)
            continue

        parsed = client.parse_json_response(br.content)
        if parsed:
            listings[i]["investment_summary"] = parsed.get("summary", "")
            listings[i]["highlight_badge"] = parsed.get("highlight_badge", "")
            listings[i]["key_strengths"] = parsed.get("key_strengths", [])
            listings[i]["key_risks"] = parsed.get("key_risks", [])

            context = _build_score_context(listings[i])
            client.set_cached("investment_summary", {"context": context[:600]}, parsed,
                              model=DEFAULT_MODEL,
                              input_tokens=br.input_tokens,
                              output_tokens=br.output_tokens)
            success_count += 1

    logger.info("サマリー生成完了: %d/%d件成功", success_count, len(requests))
    return listings


def main():
    parser = argparse.ArgumentParser(description="Claude 投資判断サマリー生成")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--skip-filter", action="store_true",
                        help="有望物件フィルタを無効化して全件処理する")
    args = parser.parse_args()

    with open(args.input, encoding="utf-8") as f:
        listings = json.load(f)

    listings = generate_investment_summaries(listings, skip_filter=args.skip_filter)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
