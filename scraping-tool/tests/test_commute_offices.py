"""commute_offices.load_office_locations の単体テスト。"""

import json

import commute_offices


def test_default_returns_placeholder_without_pii(monkeypatch):
    monkeypatch.delenv("COMMUTE_OFFICES_JSON", raising=False)
    offices = commute_offices.load_office_locations()
    assert set(offices) == {"playground", "m3career"}
    # プレースホルダに実住所・座標・法人正式名が含まれないこと
    serialized = json.dumps(offices, ensure_ascii=False)
    for leaked in ("一番町", "虎ノ門", "株式会社", "35.68", "139.74", "35.66"):
        assert leaked not in serialized
    assert offices["playground"]["lat"] == 0.0
    assert offices["m3career"]["lon"] == 0.0


def test_env_override_merges(monkeypatch):
    monkeypatch.setenv(
        "COMMUTE_OFFICES_JSON",
        json.dumps({"playground": {"address": "東京都港区テスト1-2-3", "lat": 35.1, "lon": 139.2}}),
    )
    offices = commute_offices.load_office_locations()
    assert offices["playground"]["address"] == "東京都港区テスト1-2-3"
    assert offices["playground"]["lat"] == 35.1
    # override されていないキーはプレースホルダのまま
    assert offices["m3career"]["address"] == "東京都（住所未設定）"
    # override されていないフィールド（short）は保持
    assert offices["playground"]["short"] == "PG"


def test_invalid_json_falls_back_to_placeholder(monkeypatch):
    monkeypatch.setenv("COMMUTE_OFFICES_JSON", "{not valid json")
    offices = commute_offices.load_office_locations()
    assert offices["playground"]["address"] == "東京都（住所未設定）"
