#!/usr/bin/env python3
"""
Extract Tokyo station codes from national land numerical information (国土数値情報) railway data.
Outputs station codes for use with the reinfolib real estate API.

Expects N02-22_Station.geojson from:
https://nlftp.mlit.go.jp/ksj/gml/data/N02/N02-22/N02-22_GML.zip
extracted to data/n02_temp/UTF-8/
"""

import json
import shutil
from pathlib import Path

# Tokyo bounding box: lat 35.5-35.9, lon 139.4-139.95
# GeoJSON uses [lon, lat] order
TOKYO_LON_MIN = 139.4
TOKYO_LON_MAX = 139.95
TOKYO_LAT_MIN = 35.5
TOKYO_LAT_MAX = 35.9


def in_tokyo_area(lon: float, lat: float) -> bool:
    """Check if coordinate falls within Tokyo area bounding box."""
    return (
        TOKYO_LON_MIN <= lon <= TOKYO_LON_MAX
        and TOKYO_LAT_MIN <= lat <= TOKYO_LAT_MAX
    )


def any_coord_in_tokyo(coords: list) -> bool:
    """Check if any coordinate in LineString falls within Tokyo area."""
    for point in coords:
        if len(point) >= 2:
            lon, lat = point[0], point[1]
            if in_tokyo_area(lon, lat):
                return True
    return False


def main():
    base_dir = Path(__file__).resolve().parent.parent
    data_dir = base_dir / "data"
    geojson_path = data_dir / "n02_temp" / "UTF-8" / "N02-22_Station.geojson"
    output_path = data_dir / "tokyo_station_codes.json"

    if not geojson_path.exists():
        print(f"Error: Station GeoJSON not found at {geojson_path}")
        print("Please extract N02-22_GML.zip to data/n02_temp/ first.")
        return 1

    with open(geojson_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    # Deduplicate by group_code (N02_005g)
    stations_by_group: dict[str, dict] = {}

    for feature in data.get("features", []):
        props = feature.get("properties", {})
        geom = feature.get("geometry", {})

        station_name = props.get("N02_005", "")
        group_code = props.get("N02_005g", "")
        line_name = props.get("N02_003", "")
        operator = props.get("N02_004", "")

        if not group_code:
            continue

        coords = geom.get("coordinates", [])
        if not any_coord_in_tokyo(coords):
            continue

        if group_code not in stations_by_group:
            stations_by_group[group_code] = {
                "group_code": group_code,
                "station_name": station_name,
                "lines": [],
                "operators": [],
            }

        entry = stations_by_group[group_code]
        if line_name and line_name not in entry["lines"]:
            entry["lines"].append(line_name)
        if operator and operator not in entry["operators"]:
            entry["operators"].append(operator)

    # Build output: list of stations, sorted by group_code
    stations_list = sorted(
        stations_by_group.values(),
        key=lambda s: (s["station_name"], s["group_code"]),
    )

    output = {
        "stations": stations_list,
        "count": len(stations_list),
    }

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)

    print(f"Output saved to: {output_path}")
    print(f"Total unique Tokyo stations: {len(stations_list)}")

    # Clean up temp directory
    temp_dir = data_dir / "n02_temp"
    if temp_dir.exists():
        shutil.rmtree(temp_dir)
        print(f"Cleaned up temp directory: {temp_dir}")

    return 0


if __name__ == "__main__":
    exit(main())
