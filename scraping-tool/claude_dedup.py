#!/usr/bin/env python3
"""
Claude API によるセマンティック名寄せモジュール。

既存3段階 dedup（listing_key → fuzzy_identity_match → building_key）の後段に追加し、
ルールベースでマージできなかった「同一建物内の同一部屋候補」を Claude に判定させる。

結果:
- confidence >= 0.9: 自動マージ
- 0.6 <= confidence < 0.9: フラグ表示（iOS で「同じ物件かも？」）
- confidence < 0.6: 別物件確定
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from logger import get_logger

logger = get_logger(__name__)

SYSTEM_PROMPT = """あなたは不動産物件の同一性を判定するエキスパートです。
2件の物件情報が与えられたとき、それらが物理的に同一の部屋（同じマンションの同じ号室）であるかを判定してください。

判定基準:
- 物件名の表記揺れ（ブランド名省略、英語/日本語混在、号棟記載の有無）を考慮する
- 面積が±2m²以内なら測量誤差として許容
- 価格差はサイトごとの値付け差として許容（同一部屋でも異なることがある）
- 階数・間取りが一致し住所も近ければ、名前が多少違っても同一の可能性が高い
- 逆に面積・階数が明確に異なれば別部屋

JSON形式で回答:
{"same_unit": true/false, "confidence": 0.0-1.0, "reasoning": "判定理由（日本語、1文）"}"""


@dataclass
class DedupCandidate:
    idx_a: int
    idx_b: int
    listing_a: dict
    listing_b: dict


@dataclass
class DedupResult:
    idx_a: int
    idx_b: int
    same_unit: bool
    confidence: float
    reasoning: str


def _listing_summary(listing: dict) -> str:
    """Claude に渡す���件要約を生成。"""
    fields = {
        "物件名": listing.get("name"),
        "住所": listing.get("address"),
        "間取り": listing.get("layout"),
        "面積": f"{listing.get('area_m2')}m²" if listing.get("area_m2") else None,
        "価格": f"{listing.get('price_man')}万円" if listing.get("price_man") else None,
        "階数": f"{listing.get('floor_position')}階" if listing.get("floor_position") else None,
        "総階数": f"{listing.get('floor_total')}階建て" if listing.get("floor_total") else None,
        "築年": listing.get("built_year"),
        "総戸数": listing.get("total_units"),
        "最寄り駅": listing.get("station_line"),
        "徒歩": f"{listing.get('walk_min')}分" if listing.get("walk_min") else None,
        "ソース": listing.get("source"),
    }
    return "\n".join(f"  {k}: {v}" for k, v in fields.items() if v is not None)


def find_dedup_candidates(listings: list[dict]) -> list[DedupCandidate]:
    """既存 dedup 後、同一建物内で未マージの候補ペアを抽出。"""
    try:
        from report_utils import building_key, normalize_listing_name
    except ImportError:
        sys.path.insert(0, str(Path(__file__).parent))
        from report_utils import building_key, normalize_listing_name

    building_groups: dict[tuple, list[int]] = {}
    for i, listing in enumerate(listings):
        bk = building_key(listing)
        if bk[0]:
            building_groups.setdefault(bk, []).append(i)

    candidates = []
    for bk, indices in building_groups.items():
        if len(indices) < 2:
            continue
        for i in range(len(indices)):
            for j in range(i + 1, len(indices)):
                a = listings[indices[i]]
                b = listings[indices[j]]
                area_a = a.get("area_m2") or 0
                area_b = b.get("area_m2") or 0
                if abs(area_a - area_b) > 3:
                    continue
                price_a = a.get("price_man") or 0
                price_b = b.get("price_man") or 0
                if price_a > 0 and price_b > 0:
                    price_diff_pct = abs(price_a - price_b) / max(price_a, price_b)
                    if price_diff_pct > 0.15:
                        continue
                if a.get("source") == b.get("source"):
                    continue
                candidates.append(DedupCandidate(
                    idx_a=indices[i], idx_b=indices[j],
                    listing_a=a, listing_b=b,
                ))

    logger.info("名寄せ候補ペア: %d件", len(candidates))
    return candidates


def judge_dedup_pairs(candidates: list[DedupCandidate]) -> list[DedupResult]:
    """Claude API で候補ペアを判定。"""
    from claude_client import ClaudeClient, BatchRequest, DEFAULT_MODEL

    if not candidates:
        return []

    client = ClaudeClient()
    requests = []
    uncached_indices = []

    results: list[Optional[DedupResult]] = [None] * len(candidates)

    for i, cand in enumerate(candidates):
        cache_input = {
            "a": _listing_summary(cand.listing_a),
            "b": _listing_summary(cand.listing_b),
        }
        cached = client.get_cached("dedup", cache_input)
        if cached:
            results[i] = DedupResult(
                idx_a=cand.idx_a, idx_b=cand.idx_b,
                same_unit=cached.get("same_unit", False),
                confidence=cached.get("confidence", 0.0),
                reasoning=cached.get("reasoning", ""),
            )
        else:
            user_msg = f"物件A:\n{_listing_summary(cand.listing_a)}\n\n物件B:\n{_listing_summary(cand.listing_b)}"
            requests.append(BatchRequest(
                custom_id=f"dedup_{i}",
                messages=[{"role": "user", "content": user_msg}],
                system=SYSTEM_PROMPT,
                model=DEFAULT_MODEL,
                max_tokens=256,
            ))
            uncached_indices.append(i)

    if requests:
        logger.info("Claude API 送信: %d件（キャッシュヒット: %d件）", len(requests), len(candidates) - len(requests))
        batch_results = client.send_messages(requests)

        for br in batch_results:
            idx_str = br.custom_id.replace("dedup_", "")
            try:
                i = int(idx_str)
            except ValueError:
                continue

            cand = candidates[i]
            if br.error:
                logger.warning("dedup 判定エラー (pair %d): %s", i, br.error)
                results[i] = DedupResult(
                    idx_a=cand.idx_a, idx_b=cand.idx_b,
                    same_unit=False, confidence=0.0, reasoning=f"APIエラー: {br.error}",
                )
                continue

            parsed = client.parse_json_response(br.content)
            if parsed:
                result = DedupResult(
                    idx_a=cand.idx_a, idx_b=cand.idx_b,
                    same_unit=parsed.get("same_unit", False),
                    confidence=parsed.get("confidence", 0.0),
                    reasoning=parsed.get("reasoning", ""),
                )
                results[i] = result
                cache_input = {
                    "a": _listing_summary(cand.listing_a),
                    "b": _listing_summary(cand.listing_b),
                }
                client.set_cached("dedup", cache_input, parsed, model=DEFAULT_MODEL,
                                  input_tokens=br.input_tokens, output_tokens=br.output_tokens)
            else:
                results[i] = DedupResult(
                    idx_a=cand.idx_a, idx_b=cand.idx_b,
                    same_unit=False, confidence=0.0, reasoning="JSON パース失敗",
                )

    return [r for r in results if r is not None]


def apply_dedup_results(listings: list[dict], results: list[DedupResult]) -> list[dict]:
    """判定結果を適用。confidence 0.9以上で自動マージ、0.6-0.9でフ��グ付与。"""
    merged_indices: set[int] = set()

    sorted_results = sorted(results, key=lambda r: r.confidence, reverse=True)

    for result in sorted_results:
        if not result.same_unit:
            continue

        if result.idx_a in merged_indices or result.idx_b in merged_indices:
            continue

        if result.confidence >= 0.9:
            primary = listings[result.idx_a]
            secondary = listings[result.idx_b]

            alt_sources = primary.get("alt_sources") or []
            alt_sources.append({
                "source": secondary.get("source", ""),
                "url": secondary.get("url", ""),
                "price_man": secondary.get("price_man"),
            })
            primary["alt_sources"] = alt_sources
            primary["dedup_confidence"] = result.confidence
            primary["dedup_reasoning"] = result.reasoning

            sec_images = secondary.get("suumo_images") or []
            pri_images = primary.get("suumo_images") or []
            existing_urls = {img.get("url") for img in pri_images}
            for img in sec_images:
                if img.get("url") and img["url"] not in existing_urls:
                    pri_images.append(img)
                    existing_urls.add(img["url"])
            primary["suumo_images"] = pri_images

            merged_indices.add(result.idx_b)
            logger.info(
                "自動マージ: %s (%s) ← %s (%s) [confidence=%.2f]",
                primary.get("name"), primary.get("source"),
                secondary.get("name"), secondary.get("source"),
                result.confidence,
            )

        elif result.confidence >= 0.6:
            primary = listings[result.idx_a]
            secondary = listings[result.idx_b]
            candidates_list = primary.get("dedup_candidates") or []
            candidates_list.append({
                "source": secondary.get("source", ""),
                "url": secondary.get("url", ""),
                "price_man": secondary.get("price_man"),
                "name": secondary.get("name", ""),
                "confidence": result.confidence,
                "reasoning": result.reasoning,
            })
            primary["dedup_candidates"] = candidates_list

    output = [l for i, l in enumerate(listings) if i not in merged_indices]
    merge_count = len(merged_indices)
    flag_count = sum(1 for r in results if r.same_unit and 0.6 <= r.confidence < 0.9)
    logger.info("名寄せ結果: 自動マージ %d件, フラグ付き %d件", merge_count, flag_count)
    return output


def main():
    parser = argparse.ArgumentParser(description="Claude セマンティック名寄せ")
    parser.add_argument("--input", required=True, help="入力 JSON ファイル")
    parser.add_argument("--output", required=True, help="出力 JSON ファイル")
    args = parser.parse_args()

    with open(args.input, encoding="utf-8") as f:
        listings = json.load(f)

    original_count = len(listings)
    candidates = find_dedup_candidates(listings)

    if candidates:
        results = judge_dedup_pairs(candidates)
        listings = apply_dedup_results(listings, results)
        logger.info("名寄せ完了: %d件 → %d件", original_count, len(listings))
    else:
        logger.info("名寄せ候補なし")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
