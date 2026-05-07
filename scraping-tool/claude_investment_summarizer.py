#!/usr/bin/env python3
"""
Claude API による購入推奨度生成モジュール。

買い手プロファイルと物件データを照合し、各物件に対して:
- ai_recommendation_score: 1-5 の購入推奨度（★の数）
- ai_recommendation_summary: 総合判断の結論（1-2文）
- ai_recommendation_flags: 判断のキータグ（配列）
- ai_recommendation_action: 具体的な次のアクション

コスト最適化: デフォルトでは「有望物件」のみ Claude API に送信する。
--skip-filter オプションで全件処理も可能。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any, Optional

from logger import get_logger

logger = get_logger(__name__)

# ─────────────────────── フィルタ閾値（有望物件の判定） ───────────────────────
FILTER_LISTING_SCORE_MIN = 55
FILTER_SS_PROFIT_PCT_MIN = 50
FILTER_ASSET_RANKS_PROMISING = {"S", "A", "B"}
FILTER_PRICE_FAIRNESS_MIN = 60

_BUYER_PROFILE_PATH = Path(__file__).resolve().parent / "config" / "buyer_profile.json"


def _load_buyer_profile() -> dict:
    if not _BUYER_PROFILE_PATH.exists():
        logger.warning("buyer_profile.json が見つかりません: %s", _BUYER_PROFILE_PATH)
        return {}
    try:
        return json.loads(_BUYER_PROFILE_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        logger.warning("buyer_profile.json 読み込みエラー: %s", e)
        return {}


def _format_buyer_profile(profile: dict) -> str:
    if not profile:
        return "（買い手プロファイル未設定）"
    lines = []
    field_labels = {
        "family_composition": "家族構成",
        "household_income": "世帯年収",
        "child_plan": "子ども計画",
        "work_style": "働き方・勤務地",
        "priorities": "重視する点",
        "neighborhood_preference": "街の雰囲気の好み",
        "school_priority": "学区・教育方針",
        "commute_quality": "通勤の質の重視点",
        "weekend_lifestyle": "休日の過ごし方",
        "community_preference": "コミュニティ希望",
        "deal_breakers": "絶対NG条件",
        "planned_borrowing": "借入予定",
        "estimated_rate": "想定金利",
        "repayment_years": "返済期間",
        "monthly_payment_limit": "月額上限",
        "relocation_reason": "住み替え理由",
        "post_sale_strategy": "出口方針",
    }
    for key, label in field_labels.items():
        val = profile.get(key, "")
        if val:
            lines.append(f"- {label}: {val}")
    return "\n".join(lines)


def _is_promising(listing: dict) -> bool:
    """有望物件判定（OR条件）。"""
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


SYSTEM_PROMPT = """あなたは冷静で率直な不動産購入エージェントです。
買い手プロファイルと物件情報を照合し、「この家族にとってこの物件は買いかどうか」を総合判断してください。

## 住み替え戦略
- 1軒目は8〜10年住める中継住居が標準。売却前提。
- 例外: 資産性・流動性が非常に高く、買値に安全余白がある場合のみ5年前後の住み替えも許容。
- 5年売却はオプションであり標準ではない。

## 戦略分類（必ず判断に先立って分類する）
- 標準1軒目向き: 8〜10年住める、子ども2人まで対応、出口あり
- 例外的短期向き: 駅近・高流動性・安全余白あり、5年でも売れる
- 2軒目向き: 72㎡超、学区重視、10〜15年居住前提
- 特殊物件: 100㎡超・メゾネット・小規模低層 → 長期居住前提でのみ評価
- 見送り: NG条件該当 or 複数の重大ミスマッチ

## 推奨スペック（1軒目）
- 価格帯: 9,300万〜1.03億円（本命9,500万〜9,900万）
- 面積: 65㎡以上が本命、最低55㎡。55〜64㎡は間取り・駅力次第で検討
- 間取り: 2LDK+S〜3LDK、独立居室必須
- 駅徒歩: 7分以内（5分以内が理想）
- 築年: 2006年以降、本命2010〜2018年
- 総戸数: 50戸以上（80〜200戸がベスト）、30戸未満は原則慎重
- ランニング: 管理費+修繕積立金 月3.5万以内が望ましい、4万超は慎重

## 判断の姿勢
- 個別スコアを並べるのではなく、複合的に判断する
- メリット・デメリットは両方あることが前提。その上で「総合的に買いか」を結論づける
- 8〜10年後の売却で残債割れしないかを重視する
- 間取り・広さが子ども2人まで（3人目は状況次第）に8年以上耐えうるかを見る
- 金利1.1%でしか成立しない物件は危険。2.0%で苦しいなら慎重。2.5%で家計崩壊なら見送り
- 50年ローンは元本が減りにくいため、10年後残債を意識する
- 管理・修繕の健全性を重視。修繕積立金が安すぎる物件は値上げリスクを見る
- 価格が高い＝資産性が高いとは判断しない。高価格帯は買い手が細る
- 相場高騰を理由に高値掴みを正当化しない
- 絶対NG条件に該当する場合は即座にスコア1を付ける
- 「住みたい気持ち」と「買ってよい判断」を分ける
- 買付上限価格を必ず意識する

## スコア基準
5: 強く推奨。この家族の条件にほぼ完璧にフィット。買値に安全余白あり。
4: 推奨。弱点はあるが総合的にメリットが上回る。指値が通れば買い。
3: 条件次第。良い点と悪い点が拮抗。指値が通れば検討、通らなければ見送り。
2: 非推奨。致命的ではないが、この家族にはもっと適した物件がありそう。
1: 見送り。NG条件に該当、または複数の重大ミスマッチ。

JSON形式で回答:
{
  "score": 4,
  "conclusion": "駅近×管理良好で資産性は堅い。3LDK65m²は子ども2人目以降やや厳しいが、立地の希少性と出口の確実性が上回る。指値9,500万円以下なら買い。",
  "flags": ["立地◎", "資産性堅い", "8年後手狭リスク", "管理良好", "金利2%耐性○"],
  "action": "指値9,500万円で買付申込。管理組合資料・長期修繕計画の確認必須"
}

ルール:
- score: 1-5の整数
- conclusion: 1-2文。「なぜ買い/見送りか」をこの家族の状況に紐づけて具体的に述べる。戦略分類を踏まえた総合判断。妥当価格レンジや買付上限にも言及。
- flags: この判断を左右した主要因を3-5個のタグで（良い点も悪い点も混ぜる）
- action: 具体的な次のアクション（指値金額、確認すべき資料、見送り理由等）"""


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

    address = listing.get("address", "")
    if address:
        parts.append(f"所在地: {address}")

    station_line = listing.get("station_line", "")
    station_name = listing.get("station_name", "")
    if station_line or station_name:
        parts.append(f"路線/駅: {station_line} {station_name}")

    floor_pos = listing.get("floor_position")
    if floor_pos:
        parts.append(f"所在階: {floor_pos}階")

    direction = listing.get("direction", "")
    if direction:
        parts.append(f"向き: {direction}")

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
    if listing.get("ss_profit_pct") is not None:
        parts.append(f"儲かる確率: {listing['ss_profit_pct']}%")

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

    commute_info = listing.get("commute_info_json") or listing.get("commute_info")
    if commute_info:
        if isinstance(commute_info, str):
            try:
                commute_info = json.loads(commute_info)
            except (json.JSONDecodeError, TypeError):
                commute_info = None
        if commute_info and isinstance(commute_info, dict):
            for dest, info in commute_info.items():
                if isinstance(info, dict) and info.get("duration_min"):
                    transfers = info.get("transfers", "?")
                    parts.append(f"通勤({dest}): {info['duration_min']}分（乗換{transfers}回）")

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

    management_fee = listing.get("management_fee")
    repair_fund = listing.get("repair_reserve_fund")
    if management_fee is not None or repair_fund is not None:
        mf = f"{management_fee:,}円" if management_fee else "?"
        rf = f"{repair_fund:,}円" if repair_fund else "?"
        parts.append(f"管理費/修繕積立金: {mf} / {rf}")

    return "\n".join(parts)


def generate_investment_summaries(listings: list[dict], *, skip_filter: bool = False) -> list[dict]:
    """有望物件に購入推奨度を生成。"""
    from claude_client import ClaudeClient, BatchRequest, SONNET_MODEL

    if not ClaudeClient.is_available():
        logger.warning("ANTHROPIC_API_KEY 未設定: 推奨度生成スキップ")
        return listings

    buyer_profile = _load_buyer_profile()
    buyer_context = _format_buyer_profile(buyer_profile)

    if skip_filter:
        target_indices = list(range(len(listings)))
        logger.info("推奨度生成: フィルタ無効 (全%d件を対象)", len(listings))
    else:
        target_indices = [i for i, listing in enumerate(listings) if _is_promising(listing)]
        skipped_count = len(listings) - len(target_indices)
        logger.info(
            "推奨度生成: %d/%d件が有望物件 (%d件フィルタ除外)",
            len(target_indices), len(listings), skipped_count,
        )

    if not target_indices:
        logger.info("推奨度生成: 有望物件なし、スキップ")
        return listings

    client = ClaudeClient()
    requests: list[BatchRequest] = []
    request_indices: list[int] = []

    for i in target_indices:
        listing = listings[i]
        if listing.get("ai_recommendation_score") is not None:
            continue

        context = _build_score_context(listing)
        user_message = f"## 買い手プロファイル\n{buyer_context}\n\n## 物件情報\n{context}"

        cache_key_data = {"buyer_hash": int(hashlib.sha256(buyer_context.encode()).hexdigest()[:8], 16), "context": context[:800]}
        cached = client.get_cached("ai_recommendation", cache_key_data)
        if cached:
            listing["ai_recommendation_score"] = cached.get("score")
            listing["ai_recommendation_summary"] = cached.get("conclusion", "")
            listing["ai_recommendation_flags"] = cached.get("flags", [])
            listing["ai_recommendation_action"] = cached.get("action", "")
            # 後方互換: 旧フィールドも維持
            listing["investment_summary"] = cached.get("conclusion", "")
            listing["highlight_badge"] = _score_to_badge(cached.get("score", 3))
            listing["key_strengths"] = [f for f in cached.get("flags", []) if "◎" in f or "堅い" in f or "良" in f]
            listing["key_risks"] = [f for f in cached.get("flags", []) if "リスク" in f or "懸念" in f or "不足" in f]
            continue

        requests.append(BatchRequest(
            custom_id=f"recommendation_{i}",
            messages=[{"role": "user", "content": user_message}],
            system=SYSTEM_PROMPT,
            model=SONNET_MODEL,
            max_tokens=640,
        ))
        request_indices.append(i)

    if not requests:
        logger.info("推奨度生成: 全てキャッシュ済み")
        return listings

    logger.info("推奨度生成: %d件を送信 (model=%s)", len(requests), SONNET_MODEL)
    batch_results = client.send_messages(requests)

    success_count = 0
    for br in batch_results:
        idx_str = br.custom_id.replace("recommendation_", "")
        try:
            i = int(idx_str)
        except ValueError:
            continue

        if br.error:
            logger.warning("推奨度生成エラー (listing %d): %s", i, br.error)
            continue

        parsed = client.parse_json_response(br.content)
        if parsed:
            score = parsed.get("score", 3)
            if not isinstance(score, int) or score < 1 or score > 5:
                score = 3

            listings[i]["ai_recommendation_score"] = score
            listings[i]["ai_recommendation_summary"] = parsed.get("conclusion", "")
            listings[i]["ai_recommendation_flags"] = parsed.get("flags", [])
            listings[i]["ai_recommendation_action"] = parsed.get("action", "")
            # 後方互換
            listings[i]["investment_summary"] = parsed.get("conclusion", "")
            listings[i]["highlight_badge"] = _score_to_badge(score)
            listings[i]["key_strengths"] = [f for f in parsed.get("flags", []) if "◎" in f or "堅い" in f or "良" in f]
            listings[i]["key_risks"] = [f for f in parsed.get("flags", []) if "リスク" in f or "懸念" in f or "不足" in f]

            context = _build_score_context(listings[i])
            client.set_cached("ai_recommendation", {"buyer_hash": int(hashlib.sha256(buyer_context.encode()).hexdigest()[:8], 16), "context": context[:800]}, parsed,
                              model=SONNET_MODEL,
                              input_tokens=br.input_tokens,
                              output_tokens=br.output_tokens)
            success_count += 1

    logger.info("推奨度生成完了: %d/%d件成功", success_count, len(requests))
    return listings


def _score_to_badge(score: int) -> str:
    badges = {5: "強く推奨", 4: "推奨", 3: "条件次第", 2: "非推奨", 1: "見送り"}
    return badges.get(score, "条件次第")


def main():
    parser = argparse.ArgumentParser(description="Claude 購入推奨度生成")
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
