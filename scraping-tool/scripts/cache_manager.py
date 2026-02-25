#!/usr/bin/env python3
"""
キャッシュ管理ユーティリティ。
TTL ベースのキャッシュクリーンアップ、統計表示、圧縮を行う。
"""

import json
import os
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.parent
DATA_DIR = SCRIPT_DIR / "data"

CACHE_CONFIGS = {
    "geocode_cache.json": {"ttl_days": 90, "description": "ジオコーディング"},
    "sumai_surfin_cache.json": {"ttl_days": 30, "description": "住まいサーフィン"},
    "station_cache.json": {"ttl_days": 180, "description": "駅キャッシュ"},
    "reverse_geocode_cache.json": {"ttl_days": 90, "description": "逆ジオコーディング"},
}


def get_cache_stats(filepath: Path) -> dict:
    """キャッシュファイルの統計を取得。"""
    if not filepath.exists():
        return {"exists": False, "entries": 0, "size_kb": 0}

    size_bytes = filepath.stat().st_size
    with open(filepath, "r", encoding="utf-8") as f:
        data = json.load(f)

    entries = len(data) if isinstance(data, dict) else len(data) if isinstance(data, list) else 0
    return {
        "exists": True,
        "entries": entries,
        "size_kb": round(size_bytes / 1024, 1),
        "modified": datetime.fromtimestamp(filepath.stat().st_mtime).isoformat(),
    }


def cleanup_html_cache(max_age_days: int = 60) -> int:
    """HTML キャッシュの古いファイルを削除。"""
    html_dir = DATA_DIR / "html_cache"
    if not html_dir.exists():
        return 0

    cutoff = time.time() - (max_age_days * 86400)
    removed = 0
    manifest_path = DATA_DIR / "html_cache_manifest.json"
    manifest = {}
    if manifest_path.exists():
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)

    stale_urls = []
    for url, entry in manifest.items():
        if isinstance(entry, dict) and entry.get("fetched_at"):
            try:
                fetched = datetime.fromisoformat(entry["fetched_at"]).timestamp()
                if fetched < cutoff:
                    stale_urls.append(url)
            except (ValueError, TypeError):
                pass

    for url in stale_urls:
        del manifest[url]
        removed += 1

    if removed > 0:
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False)

    for f in html_dir.iterdir():
        if f.is_file() and f.stat().st_mtime < cutoff:
            f.unlink()
            removed += 1

    return removed


def cleanup_json_cache(filepath: Path, ttl_days: int) -> int:
    """JSON キャッシュから TTL 超過エントリを削除。timestamp フィールドがある場合のみ。"""
    if not filepath.exists():
        return 0

    with open(filepath, "r", encoding="utf-8") as f:
        data = json.load(f)

    if not isinstance(data, dict):
        return 0

    cutoff = datetime.now() - timedelta(days=ttl_days)
    original_count = len(data)
    cleaned = {}

    for key, value in data.items():
        if isinstance(value, dict):
            ts = value.get("cached_at") or value.get("fetched_at") or value.get("timestamp")
            if ts:
                try:
                    entry_time = datetime.fromisoformat(ts)
                    if entry_time < cutoff:
                        continue
                except (ValueError, TypeError):
                    pass
        cleaned[key] = value

    removed = original_count - len(cleaned)
    if removed > 0:
        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(cleaned, f, ensure_ascii=False)

    return removed


def print_stats():
    """全キャッシュの統計を表示。"""
    print("=== キャッシュ統計 ===", file=sys.stderr)
    total_size = 0

    for filename, config in CACHE_CONFIGS.items():
        path = DATA_DIR / filename
        stats = get_cache_stats(path)
        total_size += stats.get("size_kb", 0)
        status = f"{stats['entries']}件, {stats['size_kb']}KB" if stats["exists"] else "なし"
        print(f"  {config['description']} ({filename}): {status}", file=sys.stderr)

    html_dir = DATA_DIR / "html_cache"
    if html_dir.exists():
        html_files = list(html_dir.glob("*.html"))
        html_size = sum(f.stat().st_size for f in html_files) / 1024
        total_size += html_size
        print(f"  HTML キャッシュ: {len(html_files)}件, {html_size:.0f}KB", file=sys.stderr)

    print(f"  合計: {total_size:.0f}KB", file=sys.stderr)


def main():
    import argparse
    parser = argparse.ArgumentParser(description="キャッシュ管理")
    parser.add_argument("--stats", action="store_true", help="統計表示")
    parser.add_argument("--cleanup", action="store_true", help="TTL 超過エントリを削除")
    parser.add_argument("--html-max-age", type=int, default=60, help="HTML キャッシュの最大保持日数")
    args = parser.parse_args()

    if args.stats:
        print_stats()

    if args.cleanup:
        print("--- キャッシュクリーンアップ ---", file=sys.stderr)

        html_removed = cleanup_html_cache(args.html_max_age)
        print(f"  HTML キャッシュ: {html_removed}件削除", file=sys.stderr)

        for filename, config in CACHE_CONFIGS.items():
            path = DATA_DIR / filename
            removed = cleanup_json_cache(path, config["ttl_days"])
            if removed > 0:
                print(f"  {config['description']}: {removed}件削除 (TTL: {config['ttl_days']}日)", file=sys.stderr)

        print("クリーンアップ完了", file=sys.stderr)

    if not args.stats and not args.cleanup:
        print_stats()


if __name__ == "__main__":
    main()
