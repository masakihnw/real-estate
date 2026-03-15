"""ScrapingConfigMetadata の単一ソース整合テスト"""

import json
from pathlib import Path

import config


def test_config_defaults_follow_metadata():
    metadata_path = Path(__file__).resolve().parents[2] / "real-estate-ios" / "RealEstateApp" / "ScrapingConfigMetadata.json"
    data = json.loads(metadata_path.read_text(encoding="utf-8"))

    defaults = data["defaults"]
    assert config.PRICE_MIN_MAN == defaults["priceMinMan"]
    assert config.PRICE_MAX_MAN == defaults["priceMaxMan"]
    assert config.AREA_MIN_M2 == defaults["areaMinM2"]
    assert config.WALK_MIN_MAX == defaults["walkMinMax"]
    assert config.TOTAL_UNITS_MIN == defaults["totalUnitsMin"]
    assert list(config.LAYOUT_PREFIX_OK) == defaults["layoutPrefixOk"]
    assert list(config.ALLOWED_STATIONS) == defaults["allowedStations"]


def test_station_groups_are_subset_of_allowed_stations():
    metadata_path = Path(__file__).resolve().parents[2] / "real-estate-ios" / "RealEstateApp" / "ScrapingConfigMetadata.json"
    data = json.loads(metadata_path.read_text(encoding="utf-8"))
    allowed = set(data["defaults"]["allowedStations"])
    grouped = {station for group in data["stationGroups"] for station in group["stations"]}
    assert grouped.issubset(allowed)


def test_metadata_schema_required_sections_exist():
    metadata_path = Path(__file__).resolve().parents[2] / "real-estate-ios" / "RealEstateApp" / "ScrapingConfigMetadata.json"
    data = json.loads(metadata_path.read_text(encoding="utf-8"))

    required_top_keys = {"schemaVersion", "defaults", "constraints", "units", "uiText", "layoutOptions", "lineKeywords", "stationGroups"}
    assert required_top_keys.issubset(data.keys())
    assert isinstance(data["units"], dict)
    assert isinstance(data["uiText"], dict)


def test_constraints_are_valid_and_defaults_are_within_range():
    metadata_path = Path(__file__).resolve().parents[2] / "real-estate-ios" / "RealEstateApp" / "ScrapingConfigMetadata.json"
    data = json.loads(metadata_path.read_text(encoding="utf-8"))
    defaults = data["defaults"]
    constraints = data["constraints"]

    for key in ("priceMinMan", "priceMaxMan", "areaMinM2", "areaMaxM2", "walkMinMax", "totalUnitsMin", "builtYearMinOffsetYears"):
        assert constraints[key]["min"] <= constraints[key]["max"]
    assert constraints["priceMinMan"]["min"] <= defaults["priceMinMan"] <= constraints["priceMinMan"]["max"]
    assert constraints["priceMaxMan"]["min"] <= defaults["priceMaxMan"] <= constraints["priceMaxMan"]["max"]
    assert constraints["areaMinM2"]["min"] <= defaults["areaMinM2"] <= constraints["areaMinM2"]["max"]
    assert constraints["walkMinMax"]["min"] <= defaults["walkMinMax"] <= constraints["walkMinMax"]["max"]
    assert constraints["totalUnitsMin"]["min"] <= defaults["totalUnitsMin"] <= constraints["totalUnitsMin"]["max"]
    assert constraints["builtYearMinOffsetYears"]["min"] <= defaults["builtYearMinOffsetYears"] <= constraints["builtYearMinOffsetYears"]["max"]
