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
REANALYZE_ASSET_RANKS = {"S", "A"}

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
    """有望物件判定（OR条件）。asset_rank は現在全件 "S" のため除外。"""
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


SYSTEM_PROMPT = """あなたは冷静で率直な不動産購入エージェントです。
買い手プロファイルと物件情報を照合し、「この家族にとってこの物件は買いかどうか」をシナリオ別に総合判断してください。

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

## エリア優先度（買い手の予算制約を反映した選定済みリスト）
- 優先A: 東陽町、西大島、森下、蔵前、入谷、亀戸、錦糸町、清澄白河、門前仲町
- 優先B: 南砂町、大島、辰巳、東雲、豊洲、浅草橋、本所吾妻橋、大森海岸

## 権利形態の判断
- 所有権: 標準。資産性の評価はそのまま適用。
- 定期借地権: 残存期間と売却時の流動性に要注意。
  - 残存30年以下: 売却困難、ローン審査も厳しく原則見送り
  - 残存30〜50年: 8〜10年後の売却時に残存20〜40年 → 買い手が限られ値下がりリスク大
  - 残存50年超: 検討可だが所有権比で15〜25%安くないと割に合わない
  - 月額地代はランニングコストに加算して評価する
  - 借地権の譲渡・転貸制限は出口戦略に直結するため必ず確認
- 旧法借地権: 更新可能で所有権に近いが、地代・承諾料を考慮

## シナリオ適合分析（必須）
買い手プロファイル（家族構成・子ども計画・働き方）と物件の間取り・面積・立地を照合し、
「この物件ならどういう家族構成・ライフステージまで対応できるか」を具体的に分析すること。

分析の観点:
- 子どもの人数×性別×年齢の組み合わせで、この間取り・面積で何年住めるか
  （例: 子ども1人なら小学校卒業まで、2人同性なら中学まで、2人異性なら小学校高学年で限界、等）
- 子ども部屋の確保タイミング（何歳から個室が必要か、この間取りで何部屋確保できるか）
- 売却の最適タイミングと出口シミュレーション（残債・想定売却価格・損益）
- 前提条件やリスク（金利上昇、市況変動、管理費値上げ、学区変更等の影響）

毎回同じパターンを繰り返すのではなく、物件の特性（面積・間取り・立地）から
この家族にとってリアルに起こりうるシナリオを2〜3個導き出すこと。

## 判断の姿勢
- 個別スコアを並べるのではなく、複合的に判断する
- メリット・デメリットは両方あることが前提。その上で「総合的に買いか」を結論づける
- 8〜10年後の売却で残債割れしないかを重視する
- 金利上昇は賃金上昇を伴う前提で耐性を見る。現行金利でしか成立しない物件は危険。1.5%（ターミナル）で苦しいなら慎重。2.0%で賃金調整後（上限29〜31万円）でも厳しいなら見送り。2.5%以上はテールリスクとして参考評価。育休・時短中は賃金調整なし（26.7万円基準）
- 金利シナリオ別の月額上限目安: 現行0.8〜1.1%→26.7万 / 1.5%→28〜29万 / 2.0%→29〜31万 / 2.5%→31〜33万 / 3.0%→調整なし
- 50年ローンは元本が減りにくいため、10年後残債を意識する
- 管理・修繕の健全性を重視。修繕積立金が安すぎる物件は値上げリスクを見る
- 価格が高い＝資産性が高いとは判断しない。高価格帯は買い手が細る
- 相場高騰を理由に高値掴みを正当化しない
- 絶対NG条件に該当する場合は即座にスコア1を付ける
- 「住みたい気持ち」と「買ってよい判断」を分ける
- 買付上限価格を必ず意識する
- 「もっと良いエリアがある」は同予算帯で同等スペック物件が現実に存在する場合のみ
- エリアの弱点指摘時は、予算内でその弱点を解消できる代替の有無も述べる
- 価格×立地×広さ×築年×管理の複合トレードオフで評価する。単一軸で結論しない
- 予算制約は妥協ではなく合理的な戦略判断。その前提で物件を評価する

## スコア基準
5: 強く推奨。この家族の条件にほぼ完璧にフィット。買値に安全余白あり。
4: 推奨。弱点はあるが総合的にメリットが上回る。指値が通れば買い。
3: 条件次第。良い点と悪い点が拮抗。指値が通れば検討、通らなければ見送り。
2: 非推奨。致命的ではないが、この家族にはもっと適した物件がありそう。
1: 見送り。NG条件に該当、または複数の重大ミスマッチ。

JSON形式で回答:
{
  "score": 4,
  "conclusion": "駅近×管理良好で資産性は堅い。所有権で出口も確実。指値9,500万円以下なら買い。",
  "flags": ["立地◎", "資産性堅い", "所有権", "管理良好", "金利2%耐性○"],
  "scenarios": [
    {"name": "子ども2人（異性）・上の子が小学校高学年で限界", "fit": "適している", "livable_years": 8, "exit_simulation": "2035年売却: 残債6,800万、想定売却9,000-9,500万。安全余白あり。", "risk": "金利2%超で月額+2万。異性兄弟だと個室確保が1年早まる。"},
    {"name": "子ども2人（同性）・中学入学まで対応可", "fit": "適している", "livable_years": 10, "exit_simulation": "2037年売却: 残債6,200万、売却8,800-9,400万。余白十分。", "risk": "築30年超で修繕積立金値上げリスク。"},
    {"name": "子ども1人・小学校卒業まで余裕", "fit": "適している", "livable_years": 12, "exit_simulation": "2039年売却: 残債5,500万、売却8,500-9,000万。余裕あり。", "risk": "長期保有で市況変動リスク増。"}
  ],
  "action": "指値9,500万円で買付申込。管理組合資料・長期修繕計画の確認必須"
}

ルール:
- score: 1-5の整数（最適シナリオをベースにした総合スコア）
- conclusion: 1-2文。「なぜ買い/見送りか」をこの家族の状況に紐づけて具体的に。権利形態にも言及。
- flags: この判断を左右した主要因を3-5個のタグで（良い点も悪い点も混ぜる。定借なら「定借リスク」等を含める）
- scenarios: この物件に関連性の高い2〜3シナリオの配列（必須）
  - name: シナリオ名（具体的に）
  - fit: "適している"/"条件次第"/"適さない"
  - livable_years: 何年住めるか（該当する場合）
  - exit_simulation: 売却タイミング、残債、想定売却価格、損益を具体的に
  - risk: そのシナリオのリスク要因
- action: 具体的な次のアクション（指値金額、確認すべき資料、見送り理由等）"""

PROMPT_VERSION = hashlib.sha256(SYSTEM_PROMPT.encode()).hexdigest()[:12]


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
    _add("資産ランク", listing.get("asset_rank"))
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
        sections.append(f"特徴タグ: {', '.join(tags)}")

    return "\n".join(sections)


def generate_investment_summaries(listings: list[dict], *, skip_filter: bool = False) -> list[dict]:
    """有望物件に購入推奨度を生成。"""
    from claude_client import ClaudeClient, BatchRequest, CreditError, DEFAULT_MODEL

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
        has_existing_score = listing.get("ai_recommendation_score") is not None
        if has_existing_score and listing.get("asset_rank") not in REANALYZE_ASSET_RANKS:
            continue

        context = _build_score_context(listing)
        user_message = f"## 買い手プロファイル\n{buyer_context}\n\n## 物件情報\n{context}"

        cache_key_data = {
            "buyer_hash": int(hashlib.sha256(buyer_context.encode()).hexdigest()[:8], 16),
            "listing_key": _listing_stable_key(listing),
            "prompt_version": PROMPT_VERSION,
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
                "プロンプト更新による再分析: %s (asset_rank=%s)",
                listing.get("name", "?"), listing.get("asset_rank", "?"),
            )

        requests.append(BatchRequest(
            custom_id=f"recommendation_{i}",
            messages=[{"role": "user", "content": user_message}],
            system=SYSTEM_PROMPT,
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
                "prompt_version": PROMPT_VERSION,
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
