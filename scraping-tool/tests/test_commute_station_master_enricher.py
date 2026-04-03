import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from commute_station_master_enricher import Office, Station, MasterRow, build_commute_info_v2, load_listings


def test_build_commute_info_v2_selects_best_station():
    listing = {"latitude": 35.6895, "longitude": 139.7004}
    stations = [
        Station("shinjuku-east", "新宿", 35.690455, 139.700564),
        Station("ebisu-west", "恵比寿", 35.646690, 139.710106),
    ]
    offices = {
        "playground": Office("playground", "Playground株式会社", 6),
        "m3career": Office("m3career", "エムスリーキャリア株式会社", 6),
    }
    master_rows = {
        ("shinjuku-east", "playground"): MasterRow("shinjuku-east", "新宿", "playground", "wkday0900", 36, 42, 48),
        ("shinjuku-east", "m3career"): MasterRow("shinjuku-east", "新宿", "m3career", "wkday0900", 28, 34, 40),
        ("ebisu-west", "playground"): MasterRow("ebisu-west", "恵比寿", "playground", "wkday0900", 24, 29, 35),
        ("ebisu-west", "m3career"): MasterRow("ebisu-west", "恵比寿", "m3career", "wkday0900", 12, 16, 20),
    }

    encoded = build_commute_info_v2(
        listing=listing,
        offices=offices,
        stations=stations,
        master_rows=master_rows,
        candidate_k=2,
        radius_m=10_000,
        walk_speed_m_per_min=80.0,
        detour_factor=1.3,
        buffer_min=4,
        ttl_days=14,
    )

    assert encoded is not None
    assert '"playground"' in encoded
    assert '"m3career"' in encoded
    assert '"新宿"' in encoded


def test_walk_override_is_applied():
    listing = {"latitude": 35.6895, "longitude": 139.7004, "walk_override_min": 7}
    stations = [Station("shinjuku-east", "新宿", 35.690455, 139.700564)]
    offices = {"playground": Office("playground", "Playground株式会社", 6)}
    master_rows = {
        ("shinjuku-east", "playground"): MasterRow("shinjuku-east", "新宿", "playground", "wkday0900", 36, 42, 48),
    }

    encoded = build_commute_info_v2(
        listing=listing,
        offices=offices,
        stations=stations,
        master_rows=master_rows,
        candidate_k=1,
        radius_m=10_000,
        walk_speed_m_per_min=80.0,
        detour_factor=1.3,
        buffer_min=4,
        ttl_days=14,
    )

    assert encoded is not None
    assert '"walk_origin_to_station": 7' in encoded


def test_load_listings_supports_csv(tmp_path: Path):
    csv_path = tmp_path / "sample.csv"
    csv_path.write_text(
        "property_id,lat,lng,walk_override_min\n"
        "p1,35.6895,139.7004,8\n",
        encoding="utf-8",
    )

    listings = load_listings(csv_path)

    assert listings[0]["property_id"] == "p1"
    assert listings[0]["latitude"] == 35.6895
    assert listings[0]["longitude"] == 139.7004
    assert listings[0]["walk_override_min"] == 8
