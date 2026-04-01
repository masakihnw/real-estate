"""sumai_surfin_enricher の新築 enrichment 判定テスト。"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from sumai_surfin_enricher import (
    _has_meaningful_shinchiku_enrichment,
    enrich_listings,
)


def test_has_meaningful_shinchiku_enrichment_rejects_purchase_judgment_only():
    listing = {
        "ss_purchase_judgment": "購入が望ましい",
    }

    assert _has_meaningful_shinchiku_enrichment(listing) is False


def test_has_meaningful_shinchiku_enrichment_accepts_metric_fields():
    listing = {
        "ss_purchase_judgment": "購入が望ましい",
        "ss_m2_discount": -12,
    }

    assert _has_meaningful_shinchiku_enrichment(listing) is True


def test_enrich_listings_does_not_copy_incomplete_shinchiku_previous_data(tmp_path):
    current = [
        {
            "url": "https://example.com/shinchiku-a",
            "name": "テストレジデンス",
            "price_man": 8200,
            "price_max_man": 8600,
            "area_m2": 70.0,
            "area_max_m2": 72.0,
            "station_line": "東京メトロ有楽町線「豊洲」徒歩5分",
            "walk_min": 5,
            "property_type": "shinchiku",
        }
    ]
    previous = [
        {
            **current[0],
            "ss_lookup_status": "found",
            "ss_purchase_judgment": "購入が望ましい",
        }
    ]

    input_path = tmp_path / "current.json"
    output_path = tmp_path / "output.json"
    previous_path = tmp_path / "previous.json"
    input_path.write_text(json.dumps(current, ensure_ascii=False), encoding="utf-8")
    previous_path.write_text(json.dumps(previous, ensure_ascii=False), encoding="utf-8")

    enrich_listings(
        str(input_path),
        str(output_path),
        session=None,
        property_type="shinchiku",
        previous_path=str(previous_path),
    )

    result = json.loads(output_path.read_text(encoding="utf-8"))
    assert result[0].get("ss_lookup_status") is None
    assert result[0].get("ss_purchase_judgment") is None


def test_enrich_listings_copies_meaningful_shinchiku_previous_data(tmp_path):
    current = [
        {
            "url": "https://example.com/shinchiku-b",
            "name": "テストレジデンス",
            "price_man": 8200,
            "price_max_man": 8600,
            "area_m2": 70.0,
            "area_max_m2": 72.0,
            "station_line": "東京メトロ有楽町線「豊洲」徒歩5分",
            "walk_min": 5,
            "property_type": "shinchiku",
        }
    ]
    previous = [
        {
            **current[0],
            "ss_lookup_status": "found",
            "ss_purchase_judgment": "購入が望ましい",
            "ss_m2_discount": -12,
            "ss_sumai_surfin_url": "https://example.com/sumai-surfin",
        }
    ]

    input_path = tmp_path / "current.json"
    output_path = tmp_path / "output.json"
    previous_path = tmp_path / "previous.json"
    input_path.write_text(json.dumps(current, ensure_ascii=False), encoding="utf-8")
    previous_path.write_text(json.dumps(previous, ensure_ascii=False), encoding="utf-8")

    enrich_listings(
        str(input_path),
        str(output_path),
        session=None,
        property_type="shinchiku",
        previous_path=str(previous_path),
    )

    result = json.loads(output_path.read_text(encoding="utf-8"))
    assert result[0]["ss_lookup_status"] == "found"
    assert result[0]["ss_purchase_judgment"] == "購入が望ましい"
    assert result[0]["ss_m2_discount"] == -12
