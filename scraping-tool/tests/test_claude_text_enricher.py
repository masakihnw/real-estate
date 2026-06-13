"""claude_text_enricher の純ロジック特性テスト（refactor P8）。

Claude API を叩く enrich_text_features は対象外。分析対象テキスト構築
（_build_listing_text）の組み立てと、自由記述フィールドのサニタイズ・
文字数制限を固定する。プロンプト本文は変更しない。
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from claude_text_enricher import _build_listing_text  # noqa: E402


def test_build_text_includes_present_fields_only():
    text = _build_listing_text({"name": "晴海タワー", "area_m2": 70.5})
    assert "物件名: 晴海タワー" in text
    assert "面積: 70.5m²" in text
    assert "住所:" not in text  # 未設定フィールドは出さない


def test_build_text_floor_uses_question_mark_when_total_missing():
    text = _build_listing_text({"floor_position": 10})
    assert "階数: 10階/?階建て" in text


def test_build_text_floor_with_total():
    text = _build_listing_text({"floor_position": 10, "floor_total": 48})
    assert "階数: 10階/48階建て" in text


def test_build_text_empty_listing_returns_empty():
    assert _build_listing_text({}) == ""


def test_build_text_feature_tags_joined():
    text = _build_listing_text({"feature_tags": ["ペット可", "南向き"]})
    assert "特徴タグ: ペット可, 南向き" in text


def test_build_text_remarks_truncated_to_500():
    long_remark = "あ" * 600
    text = _build_listing_text({"remarks": long_remark})
    # 備考行のみ抽出して長さ確認（"備考: " プレフィックス分を除く）
    line = next(l for l in text.split("\n") if l.startswith("備考: "))
    body = line[len("備考: "):]
    assert len(body) <= 500


def test_build_text_description_fallback_when_no_remarks():
    text = _build_listing_text({"description": "リノベ済み"})
    assert "備考: リノベ済み" in text


def test_build_text_remarks_takes_priority_over_description():
    text = _build_listing_text({"remarks": "備考優先", "description": "説明"})
    assert "備考: 備考優先" in text
    assert "説明" not in text


def test_build_text_equipment_truncated_to_300():
    text = _build_listing_text({"equipment": "備" * 400})
    line = next(l for l in text.split("\n") if l.startswith("設備: "))
    body = line[len("設備: "):]
    assert len(body) <= 300
