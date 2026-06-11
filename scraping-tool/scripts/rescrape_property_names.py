#!/usr/bin/env python3
"""
Re-scrape and extract property names from SUUMO URLs.
Handles HTML cache lookup, fetching, and detail page parsing.
"""

import json
import logging
import sqlite3
from pathlib import Path
from typing import Optional
from datetime import datetime

import requests

# Import from parent scraping-tool modules
from report_utils import (
    normalize_listing_name,
    clean_listing_name,
    identity_key_str,
)
from suumo_scraper import parse_suumo_detail_html

logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)

# Cache and DB paths
SCRIPT_DIR = Path(__file__).parent.parent
DATA_DIR = SCRIPT_DIR / "data"
DB_PATH = DATA_DIR / "listings.db"
CACHE_DIR = DATA_DIR / "html_cache"
MANIFEST_PATH = CACHE_DIR / "manifest.json"


def load_cache_manifest() -> dict[str, str]:
    """Load HTML cache manifest (URL → SHA256 hash mapping)."""
    if MANIFEST_PATH.exists():
        with open(MANIFEST_PATH) as f:
            return json.load(f)
    return {}


def get_cached_html(url: str) -> Optional[str]:
    """Retrieve cached HTML for URL, if exists."""
    manifest = load_cache_manifest()
    h = manifest.get(url)
    if not h:
        return None

    html_path = CACHE_DIR / f"{h}.html"
    if html_path.exists():
        try:
            return html_path.read_text(encoding="utf-8")
        except Exception as e:
            logger.warning(f"Failed to read cached HTML {h}: {e}")
            return None

    return None


def fetch_html_fresh(url: str, session: requests.Session) -> Optional[str]:
    """Fetch HTML from URL with simple error handling."""
    try:
        headers = {
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        }
        response = session.get(url, headers=headers, timeout=10)
        response.raise_for_status()
        return response.text
    except Exception as e:
        logger.error(f"Failed to fetch {url}: {e}")
        return None


def extract_building_name_from_html(html: str, fallback_name: str = "") -> Optional[str]:
    """Extract building name from SUUMO detail page HTML."""
    import re

    try:
        # Strategy 1: Extract from <h1> tag (most reliable)
        h1_match = re.search(r'<h1[^>]*>([^<]+)</h1>', html)
        if h1_match:
            title = h1_match.group(1).strip()
            # SUUMO format is usually: "【SUUMO】BuildingName 詳細ページ"
            cleaned = clean_listing_name(title)
            normalized = normalize_listing_name(title)

            # If normalized form exists and is not just a district name
            if normalized and len(normalized) > 2 and not _is_address_district(normalized):
                logger.debug(f"    Extracted from <h1>: '{title}' → normalized: '{normalized}'")
                return title  # Return original (before clean_listing_name which may strip too much)

        # Strategy 2: Extract from meta og:title
        og_match = re.search(r'<meta\s+property="og:title"\s+content="([^"]+)"', html)
        if og_match:
            title = og_match.group(1).strip()
            normalized = normalize_listing_name(title)
            if normalized and len(normalized) > 2 and not _is_address_district(normalized):
                logger.debug(f"    Extracted from og:title: '{title}'")
                return title

        # Strategy 3: Parse detail page for structured data
        try:
            detail_data = parse_suumo_detail_html(html)
            # Even if no explicit name, the function validates the page exists
            if not detail_data.get("delisted"):
                # Use title as fallback with more aggressive cleaning
                page_title_match = re.search(r'<title>([^<]+)</title>', html)
                if page_title_match:
                    page_title = page_title_match.group(1).strip()
                    # Format: "BuildingName 中古マンション物件情報 | SUUMO"
                    # Extract before first " | "
                    parts = page_title.split(" | ")
                    candidate = parts[0].strip()
                    normalized = normalize_listing_name(candidate)
                    if normalized and len(normalized) > 2 and not _is_address_district(normalized):
                        logger.debug(f"    Extracted from page title: '{candidate}' → norm: '{normalized}'")
                        return candidate
        except Exception:
            pass

        return None

    except Exception as e:
        logger.warning(f"Error parsing HTML: {e}")
        return None


def _is_address_district(normalized_name: str) -> bool:
    """Check if a normalized name is just an address/district."""
    if not normalized_name or len(normalized_name) < 2:
        return True

    # Common district names that should be excluded
    districts = {
        "渋谷", "新宿", "銀座", "青山", "麻布", "六本木", "赤坂",
        "荻窪", "中野", "高田馬場", "飯田橋", "三田",
    }

    return normalized_name in districts


def get_listing_url(db_path: str, listing_id: int, source: str = "suumo") -> Optional[str]:
    """Get URL for a listing from SQLite listing_sources table."""
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        query = """
            SELECT url FROM listing_sources
            WHERE listing_id = ? AND source = ?
            LIMIT 1
        """
        cursor.execute(query, (listing_id, source))
        result = cursor.fetchone()
        conn.close()

        return result["url"] if result else None
    except Exception as e:
        logger.error(f"Failed to fetch URL for listing {listing_id}: {e}")
        return None


def get_listing_data(db_path: str, listing_id: int) -> Optional[dict]:
    """Get current listing data from SQLite."""
    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        query = """
            SELECT id, name, normalized_name, address, layout, area_m2, built_year
            FROM listings
            WHERE id = ?
        """
        cursor.execute(query, (listing_id,))
        result = cursor.fetchone()
        conn.close()

        return dict(result) if result else None
    except Exception as e:
        logger.error(f"Failed to fetch listing {listing_id}: {e}")
        return None


def update_listing_name(
    db_path: str,
    listing_id: int,
    new_name: str,
    normalized_name: str
) -> bool:
    """Update listing name and normalized_name in SQLite."""
    try:
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        updated_at = datetime.now().isoformat()

        query = """
            UPDATE listings
            SET name = ?, normalized_name = ?, updated_at = ?
            WHERE id = ?
        """
        cursor.execute(query, (new_name, normalized_name, updated_at, listing_id))
        conn.commit()
        conn.close()

        return cursor.rowcount > 0
    except Exception as e:
        logger.error(f"Failed to update listing {listing_id}: {e}")
        return False


def rescrape_listing(
    listing_id: int,
    db_path: str = None,
    use_cache_only: bool = False
) -> tuple[bool, str]:
    """
    Rescrape building name for a listing.

    Returns:
        (success: bool, message: str)
    """
    if db_path is None:
        db_path = str(DB_PATH)

    # Step 1: Get current listing data
    listing = get_listing_data(db_path, listing_id)
    if not listing:
        return False, f"Listing {listing_id} not found"

    old_name = listing["name"]

    # Step 2: Get URL
    url = get_listing_url(db_path, listing_id, source="suumo")
    if not url:
        return False, f"No SUUMO URL found for listing {listing_id}"

    logger.info(f"Processing listing {listing_id}: {old_name} → {url}")

    # Step 3: Fetch HTML (cache first, then fresh)
    html = get_cached_html(url)
    if html:
        logger.info(f"  ✓ Using cached HTML")
    elif not use_cache_only:
        logger.info(f"  📡 Fetching fresh HTML...")
        session = requests.Session()
        html = fetch_html_fresh(url, session)
        session.close()
        if not html:
            return False, f"Failed to fetch HTML for {url}"
    else:
        return False, f"No cached HTML available (--cache-only mode)"

    # Step 4: Extract building name
    new_name = extract_building_name_from_html(html, fallback_name=old_name)
    if not new_name or new_name == old_name:
        logger.warning(f"  ✗ Could not extract building name (fallback: {old_name})")
        return False, f"No building name extracted"

    # Step 5: Normalize
    normalized_name = normalize_listing_name(new_name)

    # Step 6: Update database
    success = update_listing_name(db_path, listing_id, new_name, normalized_name)
    if not success:
        return False, f"Failed to update database"

    logger.info(f"  ✅ Updated: '{old_name}' → '{new_name}'")
    return True, f"Updated: '{old_name}' → '{new_name}'"


def main():
    """Main entry point."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Re-scrape property names from SUUMO URLs"
    )
    parser.add_argument(
        "--listing-ids", required=True,
        help="Comma-separated listing IDs (e.g., 168962,153859)"
    )
    parser.add_argument(
        "--db", type=str, default=None,
        help="Path to SQLite database (default: scraping-tool/data/listings.db)"
    )
    parser.add_argument(
        "--cache-only", action="store_true",
        help="Only use cached HTML (no fresh fetches)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would be done (no updates)"
    )

    args = parser.parse_args()

    listing_ids = [int(x.strip()) for x in args.listing_ids.split(",")]
    db_path = args.db or str(DB_PATH)

    print(f"\n{'='*80}")
    print(f"Re-scraping {len(listing_ids)} listings...")
    print(f"{'='*80}\n")

    results = {"success": 0, "failure": 0}

    for listing_id in listing_ids:
        success, message = rescrape_listing(listing_id, db_path, use_cache_only=args.cache_only)

        if success:
            results["success"] += 1
            status = "✅ SUCCESS"
        else:
            results["failure"] += 1
            status = "❌ FAILED"

        print(f"[{status}] Listing {listing_id}: {message}")

    print(f"\n{'='*80}")
    print(f"Results: {results['success']} success, {results['failure']} failure")
    print(f"{'='*80}\n")

    return 0 if results["failure"] == 0 else 1


if __name__ == "__main__":
    exit(main())
