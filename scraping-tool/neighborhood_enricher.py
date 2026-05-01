"""
周辺環境スコアリング。
Google Places API (Nearby Search) を使用して物件周辺の施設を検索し、
生活利便性スコアを算出する。
"""

import json
import os
import time
from pathlib import Path
from typing import Any, Optional

from logger import get_logger
logger = get_logger(__name__)

# Google Places API
GOOGLE_PLACES_API_KEY = os.environ.get("GOOGLE_PLACES_API_KEY", "")

# 検索カテゴリと半径
CATEGORIES = {
    "supermarket": {"types": ["supermarket"], "radius": 500, "weight": 2.0},
    "hospital": {"types": ["hospital", "doctor"], "radius": 800, "weight": 1.5},
    "nursery": {"types": ["school"], "keyword": "保育園|幼稚園", "radius": 800, "weight": 1.5},
    "park": {"types": ["park"], "radius": 500, "weight": 1.0},
    "convenience": {"types": ["convenience_store"], "radius": 200, "weight": 1.0},
}

# スコアリング基準
SCORE_THRESHOLDS = {
    "supermarket": [(1, 3), (2, 4), (3, 5)],     # (count, score) pairs
    "hospital": [(1, 3), (2, 4), (3, 5)],
    "nursery": [(1, 3), (2, 4), (3, 5)],
    "park": [(1, 3), (2, 4), (3, 5)],
    "convenience": [(1, 2), (2, 3), (3, 4), (4, 5)],
}

CACHE_FILE = Path(__file__).parent / "data" / "places_cache.json"
CACHE_EXPIRY_DAYS = 90


def _load_cache() -> dict:
    if CACHE_FILE.exists():
        try:
            return json.loads(CACHE_FILE.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def _save_cache(cache: dict) -> None:
    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    CACHE_FILE.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")


def _cache_key(lat: float, lng: float) -> str:
    """Round to 3 decimals (~111m precision) for cache sharing among nearby listings."""
    return f"{lat:.3f},{lng:.3f}"


def _is_cache_valid(entry: dict) -> bool:
    from datetime import datetime, timedelta
    cached_at = entry.get("cached_at")
    if not cached_at:
        return False
    try:
        dt = datetime.fromisoformat(cached_at)
        return (datetime.now() - dt).days < CACHE_EXPIRY_DAYS
    except (ValueError, TypeError):
        return False


def _search_nearby(lat: float, lng: float, category: str, config: dict) -> list[dict]:
    """Google Places API Nearby Search."""
    import urllib.request
    import urllib.parse

    if not GOOGLE_PLACES_API_KEY:
        return []

    params = {
        "location": f"{lat},{lng}",
        "radius": config["radius"],
        "type": "|".join(config["types"]),
        "key": GOOGLE_PLACES_API_KEY,
    }
    if "keyword" in config:
        params["keyword"] = config["keyword"]

    url = f"https://maps.googleapis.com/maps/api/place/nearbysearch/json?{urllib.parse.urlencode(params)}"

    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            return data.get("results", [])
    except Exception as e:
        logger.warning("Places API error for %s at (%s,%s): %s", category, lat, lng, e)
        return []


def _score_category(count: int, category: str) -> int:
    """Count → score (1-5)."""
    thresholds = SCORE_THRESHOLDS.get(category, [(1, 3), (2, 4), (3, 5)])
    score = 1
    for threshold_count, threshold_score in thresholds:
        if count >= threshold_count:
            score = threshold_score
    return min(score, 5)


def get_neighborhood_scores(lat: float, lng: float) -> dict[str, Any]:
    """Return neighborhood scores for a location."""
    cache = _load_cache()
    key = _cache_key(lat, lng)

    if key in cache and _is_cache_valid(cache[key]):
        return cache[key]["scores"]

    from datetime import datetime

    scores = {}
    total_weighted = 0.0
    total_weight = 0.0

    for category, config in CATEGORIES.items():
        results = _search_nearby(lat, lng, category, config)
        count = len(results)
        score = _score_category(count, category)
        nearest_name = results[0].get("name", "") if results else None
        nearest_dist = None

        if results and "geometry" in results[0]:
            r_lat = results[0]["geometry"]["location"]["lat"]
            r_lng = results[0]["geometry"]["location"]["lng"]
            nearest_dist = _haversine(lat, lng, r_lat, r_lng)

        scores[category] = {
            "count": count,
            "score": score,
            "nearest_name": nearest_name,
            "nearest_distance_m": int(nearest_dist) if nearest_dist else None,
        }
        total_weighted += score * config["weight"]
        total_weight += config["weight"]
        time.sleep(0.2)  # Rate limiting

    overall = round(total_weighted / total_weight, 1) if total_weight > 0 else 0
    scores["overall"] = overall

    cache[key] = {
        "scores": scores,
        "cached_at": datetime.now().isoformat(),
    }
    _save_cache(cache)

    return scores


def _haversine(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Calculate distance in meters between two points."""
    import math
    R = 6371000
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lng2 - lng1)
    a = math.sin(dphi/2)**2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))


def inject_neighborhood_scores(listings: list[dict]) -> list[dict]:
    """Enrich listings with neighborhood scores using geocode data."""
    geocode_path = Path(__file__).parent / "data" / "geocode_cache.json"
    if not geocode_path.exists():
        logger.warning("geocode_cache.json not found, skipping neighborhood enrichment")
        return listings

    try:
        geocode_cache = json.loads(geocode_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return listings

    if not GOOGLE_PLACES_API_KEY:
        logger.info("GOOGLE_PLACES_API_KEY not set, skipping neighborhood enrichment")
        return listings

    enriched = 0
    for listing in listings:
        name = listing.get("name", "")
        address = listing.get("address", "")

        # Try to find geocode for this listing
        geo = geocode_cache.get(name) or geocode_cache.get(address)
        if not geo or not isinstance(geo, dict):
            continue

        lat = geo.get("lat") or geo.get("latitude")
        lng = geo.get("lng") or geo.get("longitude")
        if lat is None or lng is None:
            continue

        scores = get_neighborhood_scores(float(lat), float(lng))
        listing["neighborhood_scores"] = scores
        listing["neighborhood_overall"] = scores.get("overall", 0)
        enriched += 1

    logger.info("Neighborhood scores: %d/%d listings enriched", enriched, len(listings))
    return listings
