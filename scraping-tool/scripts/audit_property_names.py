#!/usr/bin/env python3
"""
Audit script to detect abnormal property names in SQLite or Supabase.
Identifies listings with:
- Names that are just addresses (very short, district-only)
- Names that are too short (< 4 chars) relative to normalized_name
- Names with only numbers/symbols
- Empty names
"""

import logging
import os
import re
import sqlite3
from pathlib import Path

logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)


def is_address_only_name(name: str, normalized: str) -> bool:
    """Check if name appears to be just an address/district name."""
    if not name or len(name) < 2:
        return True

    # Very short names (2-3 chars) are likely district names
    if len(normalized.strip()) <= 3:
        return True

    # Names containing only Japanese district/ward keywords
    district_keywords = [
        "渋谷", "新宿", "銀座", "青山", "麻布", "六本木", "赤坂", "四谷",
        "荻窪", "中野", "新大久保", "高田馬場", "早稲田", "神楽坂", "飯田橋",
        "三田", "六本木", "麻布", "南麻布", "西麻布", "赤坂", "溜池",
        "檜町", "扇橋", "豊洲", "晴海", "勝どき", "月島", "佃",
        "日本橋", "京橋", "銀座", "有楽町", "築地", "湊", "佐久間町"
    ]

    # Check if name matches exactly a district name
    for keyword in district_keywords:
        if name.strip() == keyword:
            return True

    return False


def is_invalid_name(name: str, normalized: str) -> bool:
    """Check if name is empty or contains only symbols."""
    if not name or not name.strip():
        return True

    # Only symbols/numbers
    if re.match(r'^[0-9\-\s\.・]+$', name):
        return True

    return False


def scan_abnormal_listings(limit: int = 1000, db_path: str = None) -> list[dict]:
    """Scan SQLite database for abnormal property names."""
    if db_path is None:
        # Default to local listings.db
        script_dir = Path(__file__).parent
        db_path = script_dir.parent / "data" / "listings.db"

    if not Path(db_path).exists():
        logger.error(f"Database not found: {db_path}")
        return []

    try:
        logger.info(f"Scanning {db_path}...")
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()

        # Fetch listings where is_active = 1 (True)
        query = """
            SELECT id, name, normalized_name, address, area_m2, built_year, property_type
            FROM listings
            WHERE is_active = 1
            LIMIT ?
        """
        cursor.execute(query, (limit,))
        listings = cursor.fetchall()
        conn.close()

        logger.info(f"Fetched {len(listings)} active listings")

        abnormal = []

        for listing in listings:
            listing_id = listing["id"]
            name = listing["name"] or ""
            normalized = listing["normalized_name"] or ""

            # Check for abnormal names
            if is_address_only_name(name, normalized):
                abnormal.append({
                    "id": listing_id,
                    "name": name,
                    "normalized_name": normalized,
                    "address": listing["address"],
                    "issue": "address_only_name",
                    "area_m2": listing["area_m2"],
                    "built_year": listing["built_year"],
                    "property_type": listing["property_type"]
                })
            elif is_invalid_name(name, normalized):
                abnormal.append({
                    "id": listing_id,
                    "name": name,
                    "normalized_name": normalized,
                    "address": listing["address"],
                    "issue": "invalid_name_symbols",
                    "area_m2": listing["area_m2"],
                    "built_year": listing["built_year"],
                    "property_type": listing["property_type"]
                })

        return abnormal

    except Exception as e:
        logger.error(f"Error scanning listings: {e}")
        return []


def print_report(abnormal: list[dict]) -> None:
    """Pretty-print the audit report."""
    if not abnormal:
        print("\n✅ No abnormal property names found!\n")
        return

    print(f"\n🔴 Found {len(abnormal)} listings with abnormal names:\n")
    print("-" * 120)
    print(f"{'ID':<8} {'Issue':<20} {'Name':<30} {'Normalized':<25} {'Address':<30}")
    print("-" * 120)

    for item in abnormal:
        issue = item["issue"]
        listing_id = item["id"]
        name = item["name"][:29]
        normalized = item["normalized_name"][:24]
        address = (item["address"] or "")[:29]

        print(f"{listing_id:<8} {issue:<20} {name:<30} {normalized:<25} {address:<30}")

    print("-" * 120)
    print(f"\nSummary by Issue:")
    issue_counts = {}
    for item in abnormal:
        issue = item["issue"]
        issue_counts[issue] = issue_counts.get(issue, 0) + 1

    for issue, count in sorted(issue_counts.items()):
        print(f"  - {issue}: {count}")


def export_csv(abnormal: list[dict], output_path: Path) -> None:
    """Export results to CSV for manual review."""
    import csv

    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "id", "name", "normalized_name", "address", "issue",
            "area_m2", "built_year", "property_type"
        ])
        writer.writeheader()
        writer.writerows(abnormal)

    logger.info(f"Exported {len(abnormal)} abnormal listings to {output_path}")


def main():
    """Main entry point."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Audit property names in SQLite database for abnormalities"
    )
    parser.add_argument(
        "--limit", type=int, default=1000,
        help="Max listings to scan (default: 1000)"
    )
    parser.add_argument(
        "--db", type=str, default=None,
        help="Path to SQLite database (default: scraping-tool/data/listings.db)"
    )
    parser.add_argument(
        "--export-csv", type=Path,
        help="Export results to CSV file"
    )

    args = parser.parse_args()

    abnormal = scan_abnormal_listings(limit=args.limit, db_path=args.db)

    print_report(abnormal)

    if args.export_csv:
        export_csv(abnormal, args.export_csv)

    # Print IDs for batch rescraping
    if abnormal:
        listing_ids = [item["id"] for item in abnormal]
        print(f"\nTo rescrape these listings, use:")
        batch_size = 10
        for i in range(0, len(listing_ids), batch_size):
            batch = listing_ids[i:i+batch_size]
            print(f"  python scripts/rescrape_property_names.py --listing-ids {','.join(map(str, batch))}")
        if len(listing_ids) > batch_size:
            print(f"\n✅ Total {len(listing_ids)} abnormal listings found")


if __name__ == "__main__":
    main()
