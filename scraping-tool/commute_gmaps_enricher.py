#!/usr/bin/env python3
"""
物件ごとの door-to-door 通勤時間を Google Maps からスクレイピングする enricher。

Playwright で Google Maps の公共交通機関経路検索を自動化し、
物件住所 → 各オフィスの通勤時間（平日朝 9:00 到着）を取得する。

commute_enricher.py（駅テーブルベース）より高精度な Google Maps 実測値を提供する。
結果は commute_info フィールドに source: "gmaps" 付きで格納される。

使い方:
  python3 commute_gmaps_enricher.py --input results/latest.json --output results/latest.json
  python3 commute_gmaps_enricher.py --input results/latest.json --output results/latest.json --workers 3
  python3 commute_gmaps_enricher.py --input results/latest.json --output results/latest.json --force
"""

import argparse
import asyncio
import json
import random
import re
import sys
import urllib.parse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

try:
    from playwright.async_api import async_playwright, Page, Browser
except ImportError:
    print(
        "[commute_gmaps] playwright が必要です: pip install playwright && python3 -m playwright install chromium",
        file=sys.stderr,
    )
    # enricher として呼ばれた場合は入出力をスルーして正常終了
    if "--input" in sys.argv:
        idx = sys.argv.index("--input")
        if idx + 1 < len(sys.argv):
            inp = sys.argv[idx + 1]
            out_idx = sys.argv.index("--output") if "--output" in sys.argv else -1
            if out_idx >= 0 and out_idx + 1 < len(sys.argv):
                outp = sys.argv[out_idx + 1]
                if inp != outp:
                    import shutil
                    shutil.copy2(inp, outp)
    sys.exit(0)

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
CACHE_DIR = ROOT / "commute_gmaps_cache"

# ---------------------------------------------------------------------------
# オフィス定義（commute_auto_audit.py と統一）
# ---------------------------------------------------------------------------
OFFICES = {
    "playground": {
        "name": "Playground",
        "address": "千代田区一番町4-6",
        "lat": 35.688449,
        "lon": 139.743415,
    },
    "m3career": {
        "name": "M3Career",
        "address": "港区虎ノ門4丁目1-28",
        "lat": 35.666018,
        "lon": 139.743807,
    },
}

ARRIVAL_TIME = "09:00"

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------
MIN_DELAY = 3
MAX_DELAY = 5
ERROR_DELAY = 15
MAX_RETRIES = 3
PAGE_TIMEOUT = 25000


# ---------------------------------------------------------------------------
# ユーティリティ
# ---------------------------------------------------------------------------

def next_weekday_date() -> tuple[int, int, int]:
    """次の平日の (年, 月, 日) を返す。"""
    jst = timezone(timedelta(hours=9))
    now = datetime.now(jst)
    d = now + timedelta(days=1)
    while d.weekday() >= 5:
        d += timedelta(days=1)
    return d.year, d.month, d.day


def listing_key(listing: dict) -> str:
    """物件の一意キー（URL 優先、なければ name+address）。"""
    return listing.get("url") or f"{listing.get('name', '')}|{listing.get('address', '')}"


def listing_origin_text(listing: dict) -> Optional[str]:
    """物件の出発地テキスト（ss_address 優先 + 物件名で補完）。"""
    addr = listing.get("ss_address") or listing.get("address")
    if not addr or not addr.strip():
        return None
    name = listing.get("name", "")
    return f"{addr} {name}".strip()


def build_transit_url(origin_text: str, office: dict) -> str:
    """transit directions URL を構築する。"""
    origin = urllib.parse.quote(origin_text)
    dest = f"{office['lat']},{office['lon']}"
    return (
        f"https://www.google.com/maps/dir/{origin}/{dest}/"
        f"data=!4m2!4m1!3e3"
    )


# ---------------------------------------------------------------------------
# デバッグ
# ---------------------------------------------------------------------------

_debug_dir: Optional[Path] = None


def _init_debug_dir() -> Path:
    global _debug_dir
    if _debug_dir is None:
        _debug_dir = CACHE_DIR / "debug"
        _debug_dir.mkdir(parents=True, exist_ok=True)
    return _debug_dir


async def _debug_screenshot(page: Page, name: str) -> None:
    try:
        d = _init_debug_dir()
        await page.screenshot(path=str(d / f"{name}.png"))
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Google Maps ページ操作（commute_auto_audit.py から流用・改変）
# ---------------------------------------------------------------------------

async def handle_consent(page: Page) -> None:
    """Cookie 同意ダイアログ処理。"""
    for selector in [
        'button:has-text("すべて同意")',
        'button:has-text("Accept all")',
        'button:has-text("同意する")',
        'button:has-text("Accept")',
        'form[action*="consent"] button',
    ]:
        try:
            btn = page.locator(selector).first
            if await btn.is_visible(timeout=2000):
                await btn.click()
                await asyncio.sleep(2)
                return
        except Exception:
            continue


async def set_arrival_time(page: Page) -> bool:
    """Google Maps の UI で到着 9:00 を設定する。"""
    try:
        await asyncio.sleep(4)

        depart_btn = None
        btn_label = ""
        for label in ["すぐに出発", "出発時刻", "到着時刻", "最終"]:
            locator = page.locator(f'button:has-text("{label}")').first
            try:
                if await locator.is_visible(timeout=2000):
                    depart_btn = locator
                    btn_label = label
                    break
            except Exception:
                continue

        if not depart_btn:
            return False

        if btn_label != "到着時刻":
            await depart_btn.click()
            await asyncio.sleep(2)

            arrived = False
            for selector in [
                '[role="menuitemradio"]:has-text("到着時刻")',
                'li:has-text("到着時刻")',
                '[data-value="arrive"]',
            ]:
                try:
                    item = page.locator(selector).first
                    if await item.is_visible(timeout=2000):
                        await item.click()
                        arrived = True
                        break
                except Exception:
                    continue

            if not arrived:
                return False

            await asyncio.sleep(3)

        time_input = page.locator('input[name="transit-time"]')
        try:
            await time_input.wait_for(state="visible", timeout=5000)
        except Exception:
            time_input = page.locator('input[type="time"]').first
            try:
                await time_input.wait_for(state="visible", timeout=3000)
            except Exception:
                return False

        await time_input.fill(ARRIVAL_TIME)
        await asyncio.sleep(0.5)

        entered_val = await time_input.input_value()
        if "9" not in entered_val and "09" not in entered_val:
            await time_input.evaluate(f"""el => {{
                el.value = "{ARRIVAL_TIME}";
                el.dispatchEvent(new Event("input", {{ bubbles: true }}));
                el.dispatchEvent(new Event("change", {{ bubbles: true }}));
            }}""")
            await asyncio.sleep(0.5)

        await time_input.press("Enter")
        await asyncio.sleep(6)

        return True

    except Exception:
        return False


async def change_origin(page: Page, origin_text: str) -> bool:
    """出発地入力欄を書き換えて再検索する（到着時刻を維持）。"""
    try:
        origin_input = None
        for selector in [
            'input[aria-label*="出発地"]',
            '.tactile-searchbox-input >> nth=0',
        ]:
            try:
                loc = page.locator(selector).first
                if await loc.is_visible(timeout=2000):
                    origin_input = loc
                    break
            except Exception:
                continue

        if not origin_input:
            return False

        await origin_input.click()
        await asyncio.sleep(0.3)
        await origin_input.fill(origin_text)
        await asyncio.sleep(2)

        await origin_input.press("Enter")
        await asyncio.sleep(5)

        return True

    except Exception:
        return False


async def extract_transit_time(page: Page) -> Optional[int]:
    """経路結果から最短通勤時間（分）を抽出する。"""
    try:
        await page.wait_for_function(
            '() => document.body.innerText.includes("分")',
            timeout=PAGE_TIMEOUT,
        )
    except Exception:
        pass

    await asyncio.sleep(3)
    times_found: list[int] = []

    try:
        hour_min_locator = page.locator("text=/\\d+\\s*時間\\s*\\d+\\s*分/")
        count = await hour_min_locator.count()
        for i in range(min(count, 10)):
            try:
                text = await hour_min_locator.nth(i).inner_text(timeout=2000)
                m = re.search(r'(\d+)\s*時間\s*(\d+)\s*分', text)
                if m:
                    val = int(m.group(1)) * 60 + int(m.group(2))
                    if 2 <= val <= 180:
                        times_found.append(val)
            except Exception:
                continue

        min_locator = page.locator("text=/^\\d{1,3}\\s*分$/")
        count = await min_locator.count()
        for i in range(min(count, 20)):
            try:
                text = (await min_locator.nth(i).inner_text(timeout=2000)).strip()
                m = re.match(r'^(\d{1,3})\s*分$', text)
                if m:
                    val = int(m.group(1))
                    if 2 <= val <= 180:
                        times_found.append(val)
            except Exception:
                continue
    except Exception:
        pass

    if not times_found:
        try:
            full_text = await page.inner_text("body")
            for line in full_text.split("\n"):
                line = line.strip()
                m = re.match(r'^(\d+)\s*時間\s*(\d+)\s*分$', line)
                if m:
                    val = int(m.group(1)) * 60 + int(m.group(2))
                    if 2 <= val <= 180:
                        times_found.append(val)
                    continue
                m = re.match(r'^(\d{1,3})\s*分$', line)
                if m:
                    val = int(m.group(1))
                    if 2 <= val <= 180:
                        times_found.append(val)
        except Exception:
            pass

    if not times_found:
        try:
            full_text = await page.inner_text("body")
            for m in re.finditer(r'(\d{1,3})\s*分', full_text):
                val = int(m.group(1))
                if 2 <= val <= 180:
                    times_found.append(val)
        except Exception:
            pass

    return min(times_found) if times_found else None


async def check_no_route(page: Page) -> bool:
    """ルートが見つからない場合を検出する。"""
    try:
        text = await page.inner_text("body")
        return any(p in text for p in [
            "ルートが見つかりません",
            "経路が見つかりません",
            "この区間の経路は",
            "Sorry, we could not calculate",
            "No routes found",
            "can't find a way",
        ])
    except Exception:
        return False


# ---------------------------------------------------------------------------
# キャッシュ管理
# ---------------------------------------------------------------------------

def load_cache() -> dict[str, dict[str, Any]]:
    """レジューム用キャッシュを読み込む。キー=物件URL, 値={playground: {minutes, ...}, m3career: {...}}"""
    cache_path = CACHE_DIR / "results.json"
    if cache_path.exists():
        try:
            with open(cache_path, encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def save_cache(cache: dict[str, dict[str, Any]]) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    with open(CACHE_DIR / "results.json", "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# ワーカー
# ---------------------------------------------------------------------------

async def _worker(
    worker_id: int,
    browser: Browser,
    work_items: list[tuple[str, str, str]],  # [(listing_key, origin_text, office_key), ...]
    cache: dict[str, dict[str, Any]],
    counter: dict,
    lock: asyncio.Lock,
) -> list[str]:
    """1ワーカーが割り当てられた物件×オフィスを処理する。"""
    tag = f"[W{worker_id}]"
    context = await browser.new_context(
        locale="ja-JP",
        timezone_id="Asia/Tokyo",
        viewport={"width": 1280, "height": 900},
    )
    page = await context.new_page()

    await page.goto("https://www.google.com/maps", timeout=30000)
    await asyncio.sleep(2)
    await handle_consent(page)

    failed: list[str] = []
    consecutive_failures = 0
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # オフィスごとにグループ化して処理（到着時刻を維持するため）
    by_office: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for lkey, origin, office_key in work_items:
        by_office[office_key].append((lkey, origin))

    for office_key, items in by_office.items():
        office = OFFICES[office_key]
        is_first = True

        for lkey, origin_text in items:
            async with lock:
                counter["done"] += 1
                current = counter["done"]
                total = counter["total"]

            short_name = origin_text[:30] + ("..." if len(origin_text) > 30 else "")
            prefix = f"[{current}/{total}]"
            success = False

            for attempt in range(1, MAX_RETRIES + 1):
                try:
                    print(
                        f"{tag}{prefix} {short_name} → {office['name']} ",
                        end="", flush=True,
                    )

                    if is_first:
                        url = build_transit_url(origin_text, office)
                        await page.goto(url, timeout=30000)
                        ok = await set_arrival_time(page)
                        if not ok:
                            print("→ 到着設定失敗 ✗")
                            break
                        is_first = False
                    else:
                        ok = await change_origin(page, origin_text)
                        if not ok:
                            url = build_transit_url(origin_text, office)
                            await page.goto(url, timeout=30000)
                            ok = await set_arrival_time(page)
                            if not ok:
                                print("→ 再設定失敗 ✗")
                                break

                    if await check_no_route(page):
                        print("⚠ ルートなし")
                        success = True
                        break

                    time_min = await extract_transit_time(page)

                    if time_min is not None:
                        async with lock:
                            if lkey not in cache:
                                cache[lkey] = {}
                            cache[lkey][office_key] = {
                                "minutes": time_min,
                                "summary": f"Google Maps経路 (朝9:00到着)",
                                "calculatedAt": now_iso,
                                "source": "gmaps",
                            }
                            save_cache(cache)

                        print(f"→ {time_min}分 ✓")
                        success = True
                        consecutive_failures = 0
                        break
                    else:
                        if attempt < MAX_RETRIES:
                            print(f"取得失敗 (リトライ {attempt}/{MAX_RETRIES})")
                            is_first = True
                            await asyncio.sleep(ERROR_DELAY)
                        else:
                            print("取得失敗 ✗")

                except Exception as e:
                    if attempt < MAX_RETRIES:
                        print(f"エラー (リトライ {attempt}/{MAX_RETRIES})")
                        is_first = True
                        await asyncio.sleep(ERROR_DELAY)
                    else:
                        print(f"エラー: {e} ✗")

            if not success:
                failed.append(lkey)
                consecutive_failures += 1
                if consecutive_failures >= 5:
                    print(f"\n{tag} ⚠ 5回連続失敗。30秒待機...")
                    await asyncio.sleep(30)
                    consecutive_failures = 0
                    is_first = True

            delay = random.uniform(MIN_DELAY, MAX_DELAY)
            await asyncio.sleep(delay)

    await context.close()
    return failed


# ---------------------------------------------------------------------------
# メイン処理
# ---------------------------------------------------------------------------

def _has_gmaps_data(listing: dict) -> bool:
    """物件が既に Google Maps ベースの通勤時間データを持っているか。"""
    ci = listing.get("commute_info")
    if not ci:
        return False
    try:
        data = json.loads(ci) if isinstance(ci, str) else ci
        pg = data.get("playground", {})
        m3 = data.get("m3career", {})
        return pg.get("source") == "gmaps" and m3.get("source") == "gmaps"
    except (json.JSONDecodeError, AttributeError):
        return False


def _apply_cache_to_listings(listings: list[dict], cache: dict[str, dict[str, Any]]) -> int:
    """キャッシュの結果を物件の commute_info に反映する。"""
    updated = 0
    for listing in listings:
        lkey = listing_key(listing)
        if lkey not in cache:
            continue
        cached = cache[lkey]
        if not cached.get("playground") and not cached.get("m3career"):
            continue

        existing: dict[str, Any] = {}
        ci = listing.get("commute_info")
        if ci:
            try:
                existing = json.loads(ci) if isinstance(ci, str) else ci
            except (json.JSONDecodeError, AttributeError):
                pass

        changed = False
        for dest_key in ["playground", "m3career"]:
            if dest_key in cached and cached[dest_key].get("source") == "gmaps":
                existing[dest_key] = cached[dest_key]
                changed = True

        if changed:
            listing["commute_info"] = json.dumps(existing, ensure_ascii=False)
            updated += 1

    return updated


async def run_enrichment(
    listings: list[dict],
    force: bool = False,
    num_workers: int = 2,
    headless: bool = True,
) -> int:
    """物件リストの通勤時間を Google Maps からスクレイピングで取得する。"""
    year, month, day = next_weekday_date()
    arrival_str = f"{year}-{month:02d}-{day:02d} {ARRIVAL_TIME}"

    cache = load_cache()

    # 対象物件を特定
    targets: list[tuple[str, str]] = []  # [(listing_key, origin_text)]
    for listing in listings:
        if not force and _has_gmaps_data(listing):
            continue

        lkey = listing_key(listing)

        # キャッシュに両オフィスの結果があればスキップ
        if not force and lkey in cache:
            c = cache[lkey]
            if c.get("playground", {}).get("source") == "gmaps" and \
               c.get("m3career", {}).get("source") == "gmaps":
                continue

        origin = listing_origin_text(listing)
        if not origin:
            continue

        targets.append((lkey, origin))

    # 作業リスト（各物件 × 各オフィス、キャッシュ済みは除外）
    work_items: list[tuple[str, str, str]] = []
    for lkey, origin in targets:
        for office_key in OFFICES:
            if not force and lkey in cache and \
               cache.get(lkey, {}).get(office_key, {}).get("source") == "gmaps":
                continue
            work_items.append((lkey, origin, office_key))

    total = len(work_items)

    if total == 0:
        print("[commute_gmaps] 全物件取得済み（スキップ）", file=sys.stderr)
        updated = _apply_cache_to_listings(listings, cache)
        return updated

    actual_workers = max(1, min(num_workers, total))
    est_sec = int(total * 10.0 / actual_workers)

    print("=" * 60, file=sys.stderr)
    print("  Google Maps 通勤時間スクレイピング", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print(f"  到着時刻:     {arrival_str} JST", file=sys.stderr)
    print(f"  対象:         {len(targets)} 物件 × 2 オフィス", file=sys.stderr)
    print(f"  未取得:       {total} 件", file=sys.stderr)
    print(f"  ワーカー数:   {actual_workers}", file=sys.stderr)
    print(f"  推定所要時間: 約{est_sec // 60}分{est_sec % 60}秒", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print(file=sys.stderr)

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=headless,
            args=["--lang=ja"],
        )

        # ワーカーに分配
        worker_assignments: list[list[tuple[str, str, str]]] = [[] for _ in range(actual_workers)]
        for i, item in enumerate(work_items):
            worker_assignments[i % actual_workers].append(item)

        counter = {"done": 0, "total": total}
        lock = asyncio.Lock()

        tasks = [
            _worker(i, browser, assignment, cache, counter, lock)
            for i, assignment in enumerate(worker_assignments)
            if assignment
        ]

        failed_lists = await asyncio.gather(*tasks)
        failed = [item for sublist in failed_lists for item in sublist]

        await browser.close()

    # サマリー
    success_count = total - len(failed)
    print(f"\n[commute_gmaps] 完了: {success_count}/{total} 件成功", file=sys.stderr)
    if failed:
        print(f"[commute_gmaps] 失敗: {len(failed)} 件", file=sys.stderr)

    # キャッシュを物件に適用
    updated = _apply_cache_to_listings(listings, cache)
    print(f"[commute_gmaps] {updated} 件の commute_info を更新", file=sys.stderr)
    return updated


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="物件ごとの door-to-door 通勤時間を Google Maps からスクレイピング"
    )
    ap.add_argument("--input", required=True, help="入力 JSON ファイル")
    ap.add_argument("--output", required=True, help="出力 JSON ファイル")
    ap.add_argument("--force", action="store_true", help="全物件を再取得")
    ap.add_argument("--workers", type=int, default=2, help="並列ワーカー数（デフォルト: 2）")
    ap.add_argument(
        "--headless", action="store_true", default=True,
        help="ヘッドレスモード（デフォルト: True）",
    )
    ap.add_argument("--no-headless", action="store_true", help="ブラウザを表示して実行")
    ap.add_argument("--reset", action="store_true", help="キャッシュをリセット")
    args = ap.parse_args()

    headless = not args.no_headless

    if args.reset and CACHE_DIR.exists():
        import shutil
        shutil.rmtree(CACHE_DIR)
        print("キャッシュをリセットしました。", file=sys.stderr)

    with open(args.input, encoding="utf-8") as f:
        listings = json.load(f)

    updated = asyncio.run(
        run_enrichment(
            listings,
            force=args.force,
            num_workers=args.workers,
            headless=headless,
        )
    )

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)

    print(
        f"[commute_gmaps] enrichment 完了: {updated}/{len(listings)} 件に Google Maps 通勤時間を付与",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
