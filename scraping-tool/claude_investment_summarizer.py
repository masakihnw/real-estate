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
import os
import sys
from pathlib import Path
from typing import Any, Optional

from logger import get_logger

logger = get_logger(__name__)

# ─────────────────────── フィルタ閾値（有望物件の判定） ───────────────────────
FILTER_LISTING_SCORE_MIN = 55
FILTER_SS_PROFIT_PCT_MIN = 50
FILTER_PRICE_FAIRNESS_MIN = 60
REANALYZE_LISTING_SCORE_MIN = 65

_BUYER_PROFILE_PATH = Path(__file__).resolve().parent / "config" / "buyer_profile.json"
_DEFAULT_USER_ID = os.environ.get("BUYER_PROFILE_USER_ID", "[USER_ID]")


def _load_buyer_profile_from_supabase(user_id: str = _DEFAULT_USER_ID) -> Optional[dict]:
    try:
        import supabase_client
        client = supabase_client.get_client()
        if client is None:
            return None
        resp = client.rpc("get_buyer_profile", {"p_user_id": user_id}).execute()
        if resp.data and len(resp.data) > 0:
            logger.info("Supabase から buyer_profile を取得 (user_id=%s)", user_id)
            return resp.data[0]
    except Exception as e:
        logger.warning("Supabase buyer_profile 取得失敗 (フォールバック使用): %s", e)
    return None


def _load_buyer_profile(user_id: str = _DEFAULT_USER_ID) -> dict:
    profile = _load_buyer_profile_from_supabase(user_id)
    if profile is not None:
        return profile

    if not _BUYER_PROFILE_PATH.exists():
        logger.warning("buyer_profile.json が見つかりません: %s", _BUYER_PROFILE_PATH)
        return {}
    try:
        logger.info("ローカル buyer_profile.json からフォールバック読み込み")
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
        "self_funds": "自己資金",
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
        "interest_type": "金利タイプ",
        "estimated_rate": "想定金利",
        "repayment_years": "返済期間",
        "monthly_payment_limit": "月額上限",
        "current_housing": "現在の住居",
        "relocation_reason": "住み替え理由",
        "post_sale_strategy": "出口方針",
        "timeline": "購入時期目安",
        "risk_tolerance": "リスク許容度",
    }
    for key, label in field_labels.items():
        val = profile.get(key, "")
        if val:
            lines.append(f"- {label}: {val}")

    for jsonb_key, label in [
        ("preferred_areas", "希望エリア"),
        ("must_have_features", "必須設備"),
    ]:
        arr = profile.get(jsonb_key)
        if arr and isinstance(arr, list):
            lines.append(f"- {label}: {', '.join(str(v) for v in arr)}")

    for jsonb_key, label in [
        ("life_scenarios", "ライフシナリオ"),
        ("budget_scenarios", "予算シナリオ"),
    ]:
        scenarios = profile.get(jsonb_key)
        if not scenarios:
            continue
        if isinstance(scenarios, list):
            lines.append(f"- {label}:")
            for s in scenarios:
                if isinstance(s, dict):
                    parts = [f"{k}: {v}" for k, v in s.items() if v]
                    lines.append(f"  - {' / '.join(parts)}")
                else:
                    lines.append(f"  - {s}")
        elif isinstance(scenarios, dict):
            lines.append(f"- {label}:")
            for k, v in scenarios.items():
                if isinstance(v, (dict, list)):
                    lines.append(f"  - {k}: {json.dumps(v, ensure_ascii=False)}")
                elif v:
                    lines.append(f"  - {k}: {v}")
    return "\n".join(lines)


def _is_promising(listing: dict) -> bool:
    """有望物件判定（OR条件）。"""
    listing_score = listing.get("listing_score")
    if listing_score is not None and listing_score >= FILTER_LISTING_SCORE_MIN:
        return True

    ss_profit = listing.get("ss_profit_pct")
    if ss_profit is not None and ss_profit >= FILTER_SS_PROFIT_PCT_MIN:
        return True

    price_fairness = listing.get("price_fairness_score")
    if price_fairness is not None and price_fairness >= FILTER_PRICE_FAIRNESS_MIN:
        return True

    return False


_STRATEGY_PROMPT_PATH = Path(__file__).resolve().parent / "config" / "purchase_strategy.md"
_TASK_PROMPT_PATH = Path(__file__).resolve().parent / "config" / "prompts" / "investment_summary.md"

# 正準ソースは purchase_strategy.md（共有戦略）＋ prompts/investment_summary.md（タスク定義）。
# 本番は Supabase の system_prompt + purchase_strategy 注入を優先するため、ここは不通時フォールバック。
# import を絶対に落とさないための最小限の安全網（.md 不在・読込失敗時のみ使用）。
_EMBEDDED_SAFETY_PROMPT = (
    "あなたは冷静で率直な不動産購入エージェントです。\n"
    "買い手プロファイルと物件情報を照合し、購入可否をシナリオ別に総合判断し、"
    "score(1-5)/conclusion/flags/scenarios/action を持つJSONで回答してください。"
)


def build_fallback_system_prompt() -> str:
    """購入戦略（purchase_strategy.md）＋タスク定義（prompts/investment_summary.md）を決定論的に合成する。

    合成順は「戦略 → タスク定義」で固定（JSON スキーマがプロンプト末尾に来るようにする）。
    Supabase 経路（system_prompt=タスク定義、user 側に戦略注入）と同等の情報構成。
    本番は Supabase を優先するため、これは不通時フォールバック。
    import を落とさないため、ファイル不在・読込失敗・空ファイル時は安全網プロンプトを返す。
    """
    try:
        strategy = _STRATEGY_PROMPT_PATH.read_text(encoding="utf-8").rstrip("\n")
        task = _TASK_PROMPT_PATH.read_text(encoding="utf-8").rstrip("\n")
        if strategy and task:
            return f"## 購入戦略コンテキスト\n{strategy}\n\n{task}"
        logger.warning(
            "戦略/タスク定義 md が空です: %s, %s", _STRATEGY_PROMPT_PATH, _TASK_PROMPT_PATH
        )
    except OSError as e:
        logger.warning("戦略/タスク定義 md 読み込み失敗（安全網使用）: %s", e)
    return _EMBEDDED_SAFETY_PROMPT


_FALLBACK_SYSTEM_PROMPT = build_fallback_system_prompt()
_FALLBACK_PROMPT_VERSION = hashlib.sha256(_FALLBACK_SYSTEM_PROMPT.encode()).hexdigest()[:12]

# prepopulate_cache.py 互換の公開エイリアス（フォールバック時のキャッシュキーに使用）。
PROMPT_VERSION = _FALLBACK_PROMPT_VERSION


def _load_system_prompt_from_supabase() -> Optional[tuple[str, str]]:
    """ai_prompts テーブルから system_prompt と prompt_hash を取得。"""
    try:
        import supabase_client
        client = supabase_client.get_client()
        if client is None:
            return None
        resp = client.rpc("get_active_prompt", {"p_module": "investment_summary"}).execute()
        if resp.data and len(resp.data) > 0:
            row = resp.data[0]
            prompt = row.get("system_prompt", "")
            prompt_hash = row.get("prompt_hash", "")
            if prompt:
                logger.info("Supabase から system_prompt を取得 (module=investment_summary)")
                version = prompt_hash[:12] if prompt_hash else hashlib.sha256(prompt.encode()).hexdigest()[:12]
                return prompt, version
    except Exception as e:
        logger.warning("Supabase system_prompt 取得失敗 (フォールバック使用): %s", e)
    return None


def _load_system_prompt() -> tuple[str, str]:
    """system_prompt と prompt_version を返す。Supabase 優先、フォールバックはハードコード。"""
    result = _load_system_prompt_from_supabase()
    if result is not None:
        return result
    return _FALLBACK_SYSTEM_PROMPT, _FALLBACK_PROMPT_VERSION


def _listing_stable_key(listing: dict) -> str:
    """キャッシュキー用の安定ハッシュ。派生スコアの変動でキャッシュミスしない。"""
    fields = json.dumps({
        "name": listing.get("name"), "price_man": listing.get("price_man"),
        "area_m2": listing.get("area_m2"), "layout": listing.get("layout"),
        "built_year": listing.get("built_year"), "walk_min": listing.get("walk_min"),
        "address": listing.get("address"),
    }, sort_keys=True)
    return hashlib.sha256(fields.encode()).hexdigest()[:16]


def _parse_json_field(value: Any) -> Any:
    """JSON文字列またはdict/listを解析。"""
    if value is None or value == "":
        return None
    if isinstance(value, (dict, list)):
        return value
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (json.JSONDecodeError, TypeError):
            return None
    return None


def _build_score_context(listing: dict) -> str:
    """物件の全情報をAI分析用テキストに変換。"""
    sections: list[str] = []

    def _add(label: str, value: Any, suffix: str = "") -> None:
        if value is not None and value != "" and value != []:
            sections.append(f"{label}: {value}{suffix}")

    _add("物件名", listing.get("name"))
    _add("価格", listing.get("price_man"), "万円")
    _add("面積", listing.get("area_m2"), "m²")
    _add("バルコニー面積", listing.get("balcony_area_m2"), "m²")
    _add("間取り", listing.get("layout"))
    _add("築年", listing.get("built_year"), "年")
    _add("所在地", listing.get("address"))

    station_line = listing.get("station_line", "")
    station_name = listing.get("station_name", "")
    if station_line or station_name:
        sections.append(f"路線/駅: {station_line} {station_name}")
    _add("徒歩", listing.get("walk_min"), "分")

    floor_pos = listing.get("floor_position")
    floor_total = listing.get("floor_total")
    if floor_pos:
        sections.append(f"所在階: {floor_pos}階/{floor_total or '?'}階建て")
    _add("建物構造", listing.get("floor_structure"))
    _add("総戸数", listing.get("total_units"), "戸")
    _add("向き", listing.get("direction"))
    _add("権利形態", listing.get("ownership"))
    _add("引渡予定", listing.get("delivery_date"))
    _add("駐車場", listing.get("parking"))
    _add("用途地域", listing.get("zoning"))

    mf = listing.get("management_fee")
    rf = listing.get("repair_reserve_fund")
    if mf is not None or rf is not None:
        mf_s = f"{mf:,}円" if mf else "不明"
        rf_s = f"{rf:,}円" if rf else "不明"
        sections.append(f"管理費/修繕積立金: {mf_s} / {rf_s}")

    _add("総合投資スコア", listing.get("listing_score"), "/100")
    _add("価格妥当性スコア", listing.get("price_fairness_score"), "/100（50=適正、高い=割安）")
    _add("再販流動性スコア", listing.get("resale_liquidity_score"), "/100")
    _add("グレード", listing.get("asset_grade"))
    if listing.get("is_cheapest_in_building"):
        sections.append("棟内最安値: はい")

    _add("SS購入判断", listing.get("ss_purchase_judgment") or listing.get("ss_value_judgment"))
    _add("SS値上がり率", listing.get("ss_appreciation_rate"), "%")
    _add("SS儲かる確率", listing.get("ss_profit_pct"), "%")
    _add("SSお気に入り数", listing.get("ss_favorite_count"))
    _add("SS沖式70m²換算価格", listing.get("ss_oki_price_70m2"), "万円")
    _add("SSシミュレーション基準価格", listing.get("ss_sim_base_price"), "万円")

    radar = _parse_json_field(listing.get("ss_radar_data"))
    if radar and isinstance(radar, dict):
        radar_parts = [f"{k}={v}" for k, v in radar.items() if v is not None]
        if radar_parts:
            sections.append(f"SSレーダー: {', '.join(radar_parts)}")

    _add("棟内競合数", listing.get("competing_listings_count"), "件")
    _add("競合価格帯", listing.get("competing_price_range"))

    hazard = _parse_json_field(listing.get("hazard_info"))
    if hazard and isinstance(hazard, dict):
        risk_items = []
        overall = hazard.get("overall_risk")
        if overall:
            risk_items.append(f"総合={overall}")
        for key, label in [
            ("flood", "洪水"), ("sediment", "土砂災害"), ("storm_surge", "高潮"),
            ("tsunami", "津波"), ("liquefaction", "液状化"), ("inland_water", "内水氾濫"),
        ]:
            if hazard.get(key):
                risk_items.append(f"{label}:あり")
        for key, label in [
            ("building_collapse", "建物倒壊"), ("fire", "火災"), ("combined", "総合"),
        ]:
            val = hazard.get(key)
            if val is not None:
                risk_items.append(f"{label}危険度:{val}")
        if risk_items:
            sections.append(f"災害リスク: {', '.join(risk_items)}")

    commute_v2 = _parse_json_field(listing.get("commute_info_v2"))
    if commute_v2 and isinstance(commute_v2, dict):
        for dest, info in commute_v2.get("offices", {}).items():
            if isinstance(info, dict):
                rep = info.get("representative_minutes")
                rng = info.get("range_minutes", {})
                station = info.get("selected_station", {}).get("name", "")
                if rep:
                    rng_str = f"({rng.get('min','?')}〜{rng.get('max','?')}分)" if rng else ""
                    sections.append(f"通勤({dest}): {rep}分{rng_str} [{station}駅利用]")
    else:
        commute = _parse_json_field(listing.get("commute_info"))
        if commute and isinstance(commute, dict):
            for dest, info in commute.items():
                if isinstance(info, dict) and info.get("duration_min"):
                    sections.append(f"通勤({dest}): {info['duration_min']}分（乗換{info.get('transfers','?')}回）")

    ph = _parse_json_field(listing.get("price_history"))
    if ph and isinstance(ph, list) and len(ph) >= 1:
        entries = [f"{e.get('date','?')}: {e.get('price_man','?')}万円" for e in ph[-5:]]
        sections.append(f"価格推移: {' → '.join(entries)}（{len(ph)}回掲載）")
    _add("初回掲載日", listing.get("first_seen_at"))

    features = _parse_json_field(listing.get("extracted_features"))
    if features and isinstance(features, dict):
        _add("リノベーション", features.get("renovation_history"))
        _add("管理評価", features.get("management_quality"))
        equip = features.get("equipment_highlights")
        if equip and isinstance(equip, list) and len(equip) > 0:
            sections.append(f"設備: {', '.join(equip)}")
        _add("売却動機", features.get("seller_motivation"))
        neg = features.get("negative_factors")
        if neg and isinstance(neg, list) and len(neg) > 0:
            sections.append(f"ネガティブ要因: {', '.join(neg)}")
        _add("注目点", features.get("notable_points"))

    estat = _parse_json_field(listing.get("estat_population_data"))
    if estat and isinstance(estat, dict):
        ward = estat.get("ward", "")
        pop = estat.get("latest_population")
        chg1 = estat.get("pop_change_1yr_pct")
        chg5 = estat.get("pop_change_5yr_pct")
        if pop and chg1 is not None and chg5 is not None:
            sections.append(f"{ward}人口: {pop:,}人（1年{chg1:+.1f}%、5年{chg5:+.1f}%）")

    reinfolib = _parse_json_field(listing.get("reinfolib_market_data"))
    if reinfolib and isinstance(reinfolib, dict):
        ratio = reinfolib.get("price_ratio")
        desc = reinfolib.get("match_description", "")
        if ratio is not None:
            sections.append(f"相場比: {ratio:.3f}（{desc}）")
        _add("相場トレンド", reinfolib.get("trend"))
        _add("前年比変動", reinfolib.get("yoy_change_pct"), "%")

    tags = listing.get("feature_tags")
    if tags and isinstance(tags, list) and len(tags) > 0:
        # スクレイプ由来の自由記述はサニタイズしてから埋め込む
        from claude_client import sanitize_untrusted_text
        sections.append(f"特徴タグ: {sanitize_untrusted_text(', '.join(str(t) for t in tags))}")

    return "\n".join(sections)


def generate_investment_summaries(listings: list[dict], *, skip_filter: bool = False) -> list[dict]:
    """有望物件に購入推奨度を生成。"""
    from claude_client import ClaudeClient, BatchRequest, CreditError, DEFAULT_MODEL

    if not ClaudeClient.is_available():
        logger.warning("ANTHROPIC_API_KEY 未設定: 推奨度生成スキップ")
        return listings

    system_prompt, prompt_version = _load_system_prompt()
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
        has_existing_score = listing.get("ai_recommendation_score") is not None
        listing_score = listing.get("listing_score")
        if has_existing_score and (listing_score is None or listing_score < REANALYZE_LISTING_SCORE_MIN):
            continue

        context = _build_score_context(listing)
        user_message = f"## 買い手プロファイル\n{buyer_context}\n\n## 物件情報\n{context}"

        cache_key_data = {
            "buyer_hash": int(hashlib.sha256(buyer_context.encode()).hexdigest()[:8], 16),
            "listing_key": _listing_stable_key(listing),
            "prompt_version": prompt_version,
        }
        cached = client.get_cached("ai_recommendation", cache_key_data)
        if cached:
            listing["ai_recommendation_score"] = cached.get("score")
            listing["ai_recommendation_summary"] = cached.get("conclusion", "")
            listing["ai_recommendation_flags"] = cached.get("flags", [])
            listing["ai_recommendation_action"] = cached.get("action", "")
            listing["ai_recommendation_scenarios"] = cached.get("scenarios", [])
            # 後方互換: 旧フィールドも維持
            listing["investment_summary"] = cached.get("conclusion", "")
            listing["highlight_badge"] = _score_to_badge(cached.get("score", 3))
            listing["key_strengths"] = [f for f in cached.get("flags", []) if "◎" in f or "堅い" in f or "良" in f]
            listing["key_risks"] = [f for f in cached.get("flags", []) if "リスク" in f or "懸念" in f or "不足" in f]
            continue

        if has_existing_score:
            logger.info(
                "プロンプト更新による再分析: %s (listing_score=%s)",
                listing.get("name", "?"), listing.get("listing_score", "?"),
            )

        requests.append(BatchRequest(
            custom_id=f"recommendation_{i}",
            messages=[{"role": "user", "content": user_message}],
            system=system_prompt,
            model=DEFAULT_MODEL,
            max_tokens=2048,
            prefill="{",
        ))
        request_indices.append(i)

    if not requests:
        logger.info("推奨度生成: 全てキャッシュ済み")
        return listings

    logger.info("推奨度生成: %d件を送信 (model=%s)", len(requests), DEFAULT_MODEL)
    try:
        batch_results = client.send_messages(requests)
    except CreditError:
        logger.warning("クレジット不足: 推奨度生成をスキップします")
        return listings

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
            listings[i]["ai_recommendation_scenarios"] = parsed.get("scenarios", [])
            # 後方互換
            listings[i]["investment_summary"] = parsed.get("conclusion", "")
            listings[i]["highlight_badge"] = _score_to_badge(score)
            listings[i]["key_strengths"] = [f for f in parsed.get("flags", []) if "◎" in f or "堅い" in f or "良" in f]
            listings[i]["key_risks"] = [f for f in parsed.get("flags", []) if "リスク" in f or "懸念" in f or "不足" in f]

            client.set_cached("ai_recommendation", {
                "buyer_hash": int(hashlib.sha256(buyer_context.encode()).hexdigest()[:8], 16),
                "listing_key": _listing_stable_key(listings[i]),
                "prompt_version": prompt_version,
            }, parsed,
                              model=DEFAULT_MODEL,
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
