"""SQLite database module for the real estate scraping system.

Provides schema initialization, CRUD helpers, and the main sync_scrape_results
entry point for persisting scraped listings with historical tracking.
"""

from __future__ import annotations

import logging
import sqlite3
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

DEFAULT_DB_PATH = str(Path(__file__).resolve().parent / "data" / "listings.db")

JST = timezone(timedelta(hours=9))

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS listings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    identity_key TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    normalized_name TEXT NOT NULL,
    address TEXT,
    layout TEXT,
    area_m2 REAL,
    built_year INTEGER,
    built_str TEXT,
    station_line TEXT,
    walk_min INTEGER,
    total_units INTEGER,
    floor_position INTEGER,
    floor_total INTEGER,
    floor_structure TEXT,
    ownership TEXT,
    property_type TEXT DEFAULT 'chuko',
    developer_name TEXT,
    developer_brokerage TEXT,
    is_active BOOLEAN DEFAULT 1,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S+09:00', 'now', '+9 hours')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S+09:00', 'now', '+9 hours'))
);

CREATE TABLE IF NOT EXISTS listing_sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    listing_id INTEGER NOT NULL REFERENCES listings(id),
    source TEXT NOT NULL,
    url TEXT NOT NULL,
    price_man INTEGER,
    management_fee INTEGER,
    repair_reserve_fund INTEGER,
    listing_agent TEXT,
    is_motodzuke BOOLEAN,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    is_active BOOLEAN DEFAULT 1,
    UNIQUE(listing_id, source)
);

CREATE TABLE IF NOT EXISTS price_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    listing_id INTEGER NOT NULL REFERENCES listings(id),
    source TEXT NOT NULL,
    price_man INTEGER NOT NULL,
    recorded_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S+09:00', 'now', '+9 hours'))
);

CREATE TABLE IF NOT EXISTS listing_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    listing_id INTEGER NOT NULL REFERENCES listings(id),
    source TEXT,
    event_type TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT,
    occurred_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S+09:00', 'now', '+9 hours'))
);

CREATE TABLE IF NOT EXISTS enrichments (
    listing_id INTEGER PRIMARY KEY REFERENCES listings(id),
    asset_rank TEXT,
    asset_score_raw REAL,
    latitude REAL,
    longitude REAL,
    commute_m3 TEXT,
    commute_playground TEXT,
    ss_appreciation_rate REAL,
    ss_deviation REAL,
    near_miss BOOLEAN DEFAULT 0,
    near_miss_reasons TEXT,
    developer_priority_alert BOOLEAN DEFAULT 0,
    neighborhood_score REAL,
    neighborhood_details TEXT,
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S+09:00', 'now', '+9 hours'))
);

CREATE TABLE IF NOT EXISTS near_misses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    identity_key TEXT NOT NULL,
    name TEXT,
    source TEXT,
    url TEXT,
    price_man INTEGER,
    address TEXT,
    layout TEXT,
    area_m2 REAL,
    reasons TEXT NOT NULL,
    detected_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S+09:00', 'now', '+9 hours'))
);
"""

_INDEX_SQL = """
CREATE INDEX IF NOT EXISTS idx_listing_sources_listing_id ON listing_sources(listing_id);
CREATE INDEX IF NOT EXISTS idx_listing_sources_source ON listing_sources(source);
CREATE INDEX IF NOT EXISTS idx_price_history_listing_id ON price_history(listing_id);
CREATE INDEX IF NOT EXISTS idx_listing_events_listing_id ON listing_events(listing_id);
CREATE INDEX IF NOT EXISTS idx_listing_events_event_type ON listing_events(event_type);
CREATE INDEX IF NOT EXISTS idx_listings_is_active ON listings(is_active);
CREATE INDEX IF NOT EXISTS idx_listings_normalized_name ON listings(normalized_name);
CREATE INDEX IF NOT EXISTS idx_listings_property_type ON listings(property_type);
"""


def _now_jst() -> str:
    return datetime.now(JST).strftime("%Y-%m-%dT%H:%M:%S+09:00")


def _row_to_dict(cursor: sqlite3.Cursor, row: tuple) -> dict:
    return {col[0]: row[i] for i, col in enumerate(cursor.description)}


# ---------------------------------------------------------------------------
# Connection & schema
# ---------------------------------------------------------------------------

def get_db(db_path: str | None = None) -> sqlite3.Connection:
    """Get or create a connection to the database. Creates tables if they don't exist."""
    path = db_path or DEFAULT_DB_PATH
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = _row_to_dict
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    init_db(conn)
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    """Initialize database schema (CREATE IF NOT EXISTS)."""
    conn.executescript(_SCHEMA_SQL)
    conn.executescript(_INDEX_SQL)
    conn.commit()


# ---------------------------------------------------------------------------
# CRUD helpers
# ---------------------------------------------------------------------------

def upsert_listing(conn: sqlite3.Connection, identity_key: str, listing_data: dict) -> int:
    """Insert or update a listing. Returns the listing id."""
    now = _now_jst()
    existing = conn.execute(
        "SELECT id FROM listings WHERE identity_key = ?", (identity_key,)
    ).fetchone()

    if existing:
        listing_id = existing["id"]
        fields = [
            "name", "normalized_name", "address", "layout", "area_m2",
            "built_year", "built_str", "station_line", "walk_min",
            "total_units", "floor_position", "floor_total", "floor_structure",
            "ownership", "property_type", "developer_name", "developer_brokerage",
        ]
        set_clauses = []
        values = []
        for f in fields:
            if f in listing_data:
                set_clauses.append(f"{f} = ?")
                values.append(listing_data[f])
        if set_clauses:
            set_clauses.append("updated_at = ?")
            values.append(now)
            set_clauses.append("is_active = 1")
            values.append(listing_id)
            conn.execute(
                f"UPDATE listings SET {', '.join(set_clauses)} WHERE id = ?",
                values,
            )
        else:
            conn.execute(
                "UPDATE listings SET is_active = 1, updated_at = ? WHERE id = ?",
                (now, listing_id),
            )
        return listing_id

    cols = ["identity_key", "name", "normalized_name"]
    vals: list[Any] = [identity_key, listing_data.get("name", ""), listing_data.get("normalized_name", "")]
    optional_fields = [
        "address", "layout", "area_m2", "built_year", "built_str",
        "station_line", "walk_min", "total_units", "floor_position",
        "floor_total", "floor_structure", "ownership", "property_type",
        "developer_name", "developer_brokerage",
    ]
    for f in optional_fields:
        if f in listing_data:
            cols.append(f)
            vals.append(listing_data[f])

    placeholders = ", ".join(["?"] * len(cols))
    col_names = ", ".join(cols)
    cur = conn.execute(
        f"INSERT INTO listings ({col_names}) VALUES ({placeholders})",
        vals,
    )
    return cur.lastrowid


def upsert_listing_source(conn: sqlite3.Connection, listing_id: int, source: str, source_data: dict) -> None:
    """Insert or update a source record for a listing."""
    now = _now_jst()
    existing = conn.execute(
        "SELECT id, is_active FROM listing_sources WHERE listing_id = ? AND source = ?",
        (listing_id, source),
    ).fetchone()

    if existing:
        fields_to_update = {
            "url": source_data.get("url", ""),
            "price_man": source_data.get("price_man"),
            "management_fee": source_data.get("management_fee"),
            "repair_reserve_fund": source_data.get("repair_reserve_fund"),
            "listing_agent": source_data.get("listing_agent"),
            "is_motodzuke": source_data.get("is_motodzuke"),
            "last_seen_at": now,
            "is_active": 1,
        }
        set_parts = [f"{k} = ?" for k in fields_to_update]
        vals = list(fields_to_update.values())
        vals.append(existing["id"])
        conn.execute(
            f"UPDATE listing_sources SET {', '.join(set_parts)} WHERE id = ?",
            vals,
        )
    else:
        conn.execute(
            """INSERT INTO listing_sources
               (listing_id, source, url, price_man, management_fee,
                repair_reserve_fund, listing_agent, is_motodzuke,
                first_seen_at, last_seen_at, is_active)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)""",
            (
                listing_id, source, source_data.get("url", ""),
                source_data.get("price_man"), source_data.get("management_fee"),
                source_data.get("repair_reserve_fund"),
                source_data.get("listing_agent"), source_data.get("is_motodzuke"),
                now, now,
            ),
        )


def record_price_change(conn: sqlite3.Connection, listing_id: int, source: str, new_price: int) -> None:
    """Record a price change in price_history."""
    conn.execute(
        "INSERT INTO price_history (listing_id, source, price_man) VALUES (?, ?, ?)",
        (listing_id, source, new_price),
    )


def record_event(
    conn: sqlite3.Connection,
    listing_id: int,
    source: str | None,
    event_type: str,
    old_value: str | None = None,
    new_value: str | None = None,
) -> None:
    """Record a listing event."""
    conn.execute(
        """INSERT INTO listing_events (listing_id, source, event_type, old_value, new_value)
           VALUES (?, ?, ?, ?, ?)""",
        (listing_id, source, event_type, old_value, new_value),
    )


def mark_inactive(conn: sqlite3.Connection, listing_id: int, source: str | None = None) -> None:
    """Mark a listing (or just a source) as inactive."""
    now = _now_jst()
    if source:
        conn.execute(
            "UPDATE listing_sources SET is_active = 0, last_seen_at = ? WHERE listing_id = ? AND source = ?",
            (now, listing_id, source),
        )
        active_sources = conn.execute(
            "SELECT COUNT(*) AS cnt FROM listing_sources WHERE listing_id = ? AND is_active = 1",
            (listing_id,),
        ).fetchone()
        if active_sources["cnt"] == 0:
            conn.execute(
                "UPDATE listings SET is_active = 0, updated_at = ? WHERE id = ?",
                (now, listing_id),
            )
    else:
        conn.execute(
            "UPDATE listings SET is_active = 0, updated_at = ? WHERE id = ?",
            (now, listing_id),
        )
        conn.execute(
            "UPDATE listing_sources SET is_active = 0, last_seen_at = ? WHERE listing_id = ?",
            (now, listing_id),
        )


# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------

def get_active_listings(conn: sqlite3.Connection, source: str | None = None) -> list[dict]:
    """Get all active listings, optionally filtered by source."""
    if source:
        return conn.execute(
            """SELECT l.* FROM listings l
               JOIN listing_sources ls ON l.id = ls.listing_id
               WHERE l.is_active = 1 AND ls.source = ? AND ls.is_active = 1""",
            (source,),
        ).fetchall()
    return conn.execute(
        "SELECT * FROM listings WHERE is_active = 1"
    ).fetchall()


def get_listing_by_identity_key(conn: sqlite3.Connection, identity_key: str) -> dict | None:
    """Look up a listing by identity key.
    折衷案: 完全一致を優先し、見つからなければ floor=None 版でフォールバック検索する。
    これにより、片方の媒体に階数がない場合でも同一物件としてマージされる。"""
    exact = conn.execute(
        "SELECT * FROM listings WHERE identity_key = ?", (identity_key,)
    ).fetchone()
    if exact:
        return exact

    # フォールバック: 新キー(7要素)で見つからない場合、floor部分を None に置き換えて検索
    parts = identity_key.split("|")
    if len(parts) == 7 and parts[6] != "None":
        fallback_key = "|".join(parts[:6] + ["None"])
        found = conn.execute(
            "SELECT * FROM listings WHERE identity_key = ?", (fallback_key,)
        ).fetchone()
        if found:
            # 既存レコードの identity_key を階数ありに更新
            conn.execute(
                "UPDATE listings SET identity_key = ? WHERE id = ?",
                (identity_key, found["id"])
            )
            return found

    # フォールバック: 旧キー(6要素)との互換性
    if len(parts) == 7:
        legacy_key = "|".join(parts[:6])
        found = conn.execute(
            "SELECT * FROM listings WHERE identity_key = ?", (legacy_key,)
        ).fetchone()
        if found:
            conn.execute(
                "UPDATE listings SET identity_key = ? WHERE id = ?",
                (identity_key, found["id"])
            )
            return found

    return None


def get_listing_sources(conn: sqlite3.Connection, listing_id: int) -> list[dict]:
    """Get all sources for a listing."""
    return conn.execute(
        "SELECT * FROM listing_sources WHERE listing_id = ?", (listing_id,)
    ).fetchall()


def get_competing_count(conn: sqlite3.Connection, normalized_name: str) -> int:
    """Count active listings for the same building."""
    row = conn.execute(
        "SELECT COUNT(*) AS cnt FROM listings WHERE normalized_name = ? AND is_active = 1",
        (normalized_name,),
    ).fetchone()
    return row["cnt"] if row else 0


def get_days_on_market(conn: sqlite3.Connection, listing_id: int) -> int | None:
    """Calculate days since first seen (earliest first_seen_at across all sources)."""
    row = conn.execute(
        "SELECT MIN(first_seen_at) AS first_seen FROM listing_sources WHERE listing_id = ?",
        (listing_id,),
    ).fetchone()
    if not row or not row["first_seen"]:
        return None
    first_seen = datetime.fromisoformat(row["first_seen"])
    now = datetime.now(JST)
    return (now - first_seen).days


def get_price_history(conn: sqlite3.Connection, listing_id: int) -> list[dict]:
    """Get price history for a listing, ordered chronologically."""
    return conn.execute(
        "SELECT * FROM price_history WHERE listing_id = ? ORDER BY recorded_at",
        (listing_id,),
    ).fetchall()


# ---------------------------------------------------------------------------
# Batch sync
# ---------------------------------------------------------------------------

def sync_scrape_results(
    conn: sqlite3.Connection,
    scraped_listings: list[dict],
    source: str,
    property_type: str | None = None,
) -> dict:
    """Main entry point: sync a batch of scraped listings from one source.

    Returns a summary dict with counts of new, updated, removed, unchanged listings.

    Args:
        property_type: If provided, only mark listings of this type as inactive when
                       they're missing from the batch. Prevents cross-contamination
                       between chuko/shinchiku when they share the same source.
    """
    from report_utils import identity_key_str, normalize_listing_name

    summary = {"new": 0, "updated": 0, "removed": 0, "unchanged": 0, "reappeared": 0}
    seen_listing_ids: set[int] = set()

    for item in scraped_listings:
        ik = identity_key_str(item)
        if not ik or all(p in ("None", "") for p in ik.split("|")):
            continue

        normalized_name = normalize_listing_name(item.get("name") or "")
        listing_data = {
            "name": item.get("name", ""),
            "normalized_name": normalized_name,
            "address": item.get("address"),
            "layout": item.get("layout"),
            "area_m2": item.get("area_m2"),
            "built_year": item.get("built_year"),
            "built_str": item.get("built_str"),
            "station_line": item.get("station_line"),
            "walk_min": item.get("walk_min"),
            "total_units": item.get("total_units"),
            "floor_position": item.get("floor_position"),
            "floor_total": item.get("floor_total"),
            "floor_structure": item.get("floor_structure"),
            "ownership": item.get("ownership"),
            "property_type": item.get("property_type", "chuko"),
            "developer_name": item.get("developer_name"),
            "developer_brokerage": item.get("developer_brokerage"),
        }

        existing = get_listing_by_identity_key(conn, ik)
        existing_source = None
        was_inactive_source = False

        if existing:
            listing_id = existing["id"]
            existing_source = conn.execute(
                "SELECT * FROM listing_sources WHERE listing_id = ? AND source = ?",
                (listing_id, source),
            ).fetchone()
            if existing_source:
                was_inactive_source = not existing_source["is_active"]

        listing_id = upsert_listing(conn, ik, listing_data)
        seen_listing_ids.add(listing_id)

        source_data = {
            "url": item.get("url", ""),
            "price_man": item.get("price_man"),
            "management_fee": item.get("management_fee"),
            "repair_reserve_fund": item.get("repair_reserve_fund"),
            "listing_agent": item.get("listing_agent"),
            "is_motodzuke": item.get("is_motodzuke"),
        }

        # Detect price change before upserting source
        new_price = item.get("price_man")
        if existing_source and existing_source["is_active"] and new_price is not None:
            old_price = existing_source["price_man"]
            if old_price is not None and old_price != new_price:
                record_price_change(conn, listing_id, source, new_price)
                record_event(
                    conn, listing_id, source, "price_changed",
                    old_value=str(old_price), new_value=str(new_price),
                )
                summary["updated"] += 1
                upsert_listing_source(conn, listing_id, source, source_data)
                continue

        upsert_listing_source(conn, listing_id, source, source_data)

        if existing_source is None:
            record_event(conn, listing_id, source, "appeared")
            summary["new"] += 1
        elif was_inactive_source:
            record_event(conn, listing_id, source, "reappeared")
            summary["reappeared"] += 1
        else:
            summary["unchanged"] += 1

    # Mark listings from this source that were not in the current batch as inactive
    if property_type:
        currently_active = conn.execute(
            """SELECT ls.listing_id, ls.id AS source_id
               FROM listing_sources ls
               JOIN listings l ON l.id = ls.listing_id
               WHERE ls.source = ? AND ls.is_active = 1 AND l.property_type = ?""",
            (source, property_type),
        ).fetchall()
    else:
        currently_active = conn.execute(
            """SELECT ls.listing_id, ls.id AS source_id
               FROM listing_sources ls
               WHERE ls.source = ? AND ls.is_active = 1""",
            (source,),
        ).fetchall()

    for row in currently_active:
        if row["listing_id"] not in seen_listing_ids:
            mark_inactive(conn, row["listing_id"], source)
            record_event(conn, row["listing_id"], source, "removed")
            summary["removed"] += 1

    conn.commit()
    logger.info(
        "sync_scrape_results(%s): new=%d updated=%d removed=%d unchanged=%d reappeared=%d",
        source, summary["new"], summary["updated"], summary["removed"],
        summary["unchanged"], summary["reappeared"],
    )
    return summary
