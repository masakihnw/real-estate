#!/usr/bin/env python3
"""
通勤時間の自動取得ツール

Playwright で Google Maps の経路検索を自動化し、
各駅 → オフィスの通勤時間（平日8:30到着・公共交通機関）を一括取得する。

セットアップ:
  pip install playwright
  python3 -m playwright install chromium

使い方:
  python3 commute_auto_audit.py                       # 全駅を自動取得
  python3 commute_auto_audit.py --office playground    # PG のみ
  python3 commute_auto_audit.py --test 品川             # 1駅だけテスト
  python3 commute_auto_audit.py --workers 3            # 3並列で取得
  python3 commute_auto_audit.py --reset                # 前回の結果をリセット
  python3 commute_auto_audit.py --dry-run              # 取得せず差分だけ表示
"""

import asyncio
import json
import random
import re
import shutil
import sys
import urllib.parse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

try:
    from playwright.async_api import async_playwright, Page, Browser
except ImportError:
    print("❌ playwright が必要です。以下を実行してください:")
    print("  pip install playwright")
    print("  python3 -m playwright install chromium")
    sys.exit(1)

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
RESULTS_DIR = ROOT / "commute_audit_results"

# ---------------------------------------------------------------------------
# オフィス定義
# ---------------------------------------------------------------------------
OFFICES = {
    "playground": {
        "name": "Playground",
        "address": "千代田区一番町4-6",
        "lat": 35.688449,
        "lon": 139.743415,
        "nearby_stations": [
            {"name": "半蔵門", "walk": 5},
            {"name": "九段下", "walk": 7},
            {"name": "麹町", "walk": 11},
            {"name": "市ヶ谷", "walk": 15},
        ],
    },
    "m3career": {
        "name": "M3Career",
        "address": "港区虎ノ門4丁目1-28",
        "lat": 35.666018,
        "lon": 139.743807,
        "nearby_stations": [
            {"name": "神谷町", "walk": 7},
            {"name": "溜池山王", "walk": 12},
            {"name": "国会議事堂前", "walk": 16},
            {"name": "御成門", "walk": 18},
        ],
    },
}

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------
MIN_DELAY = 3       # リクエスト間の最小待機秒
MAX_DELAY = 5       # リクエスト間の最大待機秒
ERROR_DELAY = 15    # エラー時の待機秒
MAX_RETRIES = 3     # 1駅あたりの最大リトライ回数
PAGE_TIMEOUT = 25000  # ページ読み込みタイムアウト(ms)


# ---------------------------------------------------------------------------
# ユーティリティ
# ---------------------------------------------------------------------------

def next_weekday_date() -> tuple[int, int, int]:
    """次の平日の (年, 月, 日) を返す。"""
    jst = timezone(timedelta(hours=9))
    now = datetime.now(jst)
    d = now + timedelta(days=1)
    while d.weekday() >= 5:  # 土日スキップ
        d += timedelta(days=1)
    return d.year, d.month, d.day


def build_basic_transit_url(station: str, office: dict) -> str:
    """基本的な transit directions URL を構築する（時刻指定なし）。"""
    origin = urllib.parse.quote(f"{station}駅")
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
        _debug_dir = RESULTS_DIR / "debug"
        _debug_dir.mkdir(parents=True, exist_ok=True)
    return _debug_dir


async def _debug_screenshot(page: Page, name: str) -> None:
    """デバッグ用スクリーンショットを保存する。"""
    try:
        d = _init_debug_dir()
        await page.screenshot(path=str(d / f"{name}.png"))
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Google Maps ページ操作
# ---------------------------------------------------------------------------

async def handle_consent(page: Page) -> None:
    """Google Maps 初回表示時の Cookie 同意ダイアログを処理する。"""
    consent_selectors = [
        'button:has-text("すべて同意")',
        'button:has-text("Accept all")',
        'button:has-text("同意する")',
        'button:has-text("Accept")',
        'form[action*="consent"] button',
    ]
    for selector in consent_selectors:
        try:
            btn = page.locator(selector).first
            if await btn.is_visible(timeout=2000):
                await btn.click()
                await asyncio.sleep(2)
                return
        except Exception:
            continue


async def set_arrival_time_830(page: Page) -> bool:
    """
    Google Maps の UI を操作して「到着 8:30」に設定する。

    ★ URL パラメータ (!6e2 等) では到着時刻モードが正しく反映されないため、
      必ず UI 操作で設定する。
    ★ この関数はリロードしない。呼び出し後のページには検索結果が表示されている。

    Returns: True if successful
    """
    try:
        await asyncio.sleep(4)
        await _debug_screenshot(page, "01_before_dropdown")

        # Step 1: 時刻設定ドロップダウンを開く
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
            await _debug_screenshot(page, "01_no_button")
            print("⚠ 時刻ボタンが見つからない ", end="", flush=True)
            return False

        print(f"[ボタン:{btn_label}] ", end="", flush=True)

        if btn_label != "到着時刻":
            await depart_btn.click()
            await asyncio.sleep(2)
            await _debug_screenshot(page, "02_dropdown_opened")

            # Step 2: 「到着時刻」メニュー項目を選択
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
                await _debug_screenshot(page, "02_no_arrive_option")
                print("⚠ 到着時刻メニューが見つからない ", end="", flush=True)
                return False

            await asyncio.sleep(3)
            await _debug_screenshot(page, "03_arrival_selected")

        # Step 3: 時刻を入力
        # ★ click(click_count=3) は使わない: 時刻ピッカーが開いてフリーズするため
        time_input = page.locator('input[name="transit-time"]')
        try:
            await time_input.wait_for(state="visible", timeout=5000)
        except Exception:
            time_input = page.locator('input[type="time"]').first
            try:
                await time_input.wait_for(state="visible", timeout=3000)
            except Exception:
                await _debug_screenshot(page, "03_no_time_input")
                print("⚠ 時刻入力欄が見つからない ", end="", flush=True)
                return False

        current_val = await time_input.input_value()
        print(f"[現在値:{current_val}] ", end="", flush=True)

        await time_input.fill("08:30")
        await asyncio.sleep(0.5)

        entered_val = await time_input.input_value()
        print(f"[入力後:{entered_val}] ", end="", flush=True)
        await _debug_screenshot(page, "04_time_entered")

        if "8" not in entered_val and "08" not in entered_val:
            print("[fill失敗→evaluate] ", end="", flush=True)
            await time_input.evaluate("""el => {
                el.value = "08:30";
                el.dispatchEvent(new Event("input", { bubbles: true }));
                el.dispatchEvent(new Event("change", { bubbles: true }));
            }""")
            await asyncio.sleep(0.5)

        # Step 4: Enter で検索実行
        await time_input.press("Enter")
        await asyncio.sleep(6)
        await _debug_screenshot(page, "05_after_enter")

        # 到着時刻が設定されているか確認
        try:
            arrive_btn = page.locator('button:has-text("到着時刻")')
            if await arrive_btn.first.is_visible(timeout=2000):
                print("[到着8:30確認OK] ", end="", flush=True)
                return True
        except Exception:
            pass

        # ボタンが見つからなくても結果があればOKとする
        print("[到着8:30設定完了] ", end="", flush=True)
        return True

    except Exception as e:
        print(f"⚠ 時刻設定失敗: {e} ", end="", flush=True)
        await _debug_screenshot(page, "error")
        return False


async def change_origin(page: Page, station: str) -> bool:
    """
    出発地を変更して再検索する。到着時刻・目的地の設定は維持される。

    Google Maps の directions ビューで出発地入力欄を書き換え、
    Enterキーで検索を実行する。URLナビゲーションを使わないため
    到着時刻設定が「出発時刻」に変わる問題を回避できる。
    """
    try:
        # 出発地入力欄を特定
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

        # 出発地をクリアして新しい駅名を入力
        await origin_input.click()
        await asyncio.sleep(0.3)
        await origin_input.fill(f"{station}駅")
        await asyncio.sleep(1.5)

        # Enter で検索（オートコンプリートの1件目を選択）
        await origin_input.press("Enter")
        await asyncio.sleep(5)

        return True

    except Exception as e:
        print(f"⚠ 出発地変更失敗: {e} ", end="", flush=True)
        return False


async def extract_transit_time(page: Page) -> Optional[int]:
    """
    Google Maps の経路結果ページから最短通勤時間（分）を抽出する。
    """
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
        # "X時間Y分" パターン
        hour_min_locator = page.locator("text=/\\d+\\s*時間\\s*\\d+\\s*分/")
        count = await hour_min_locator.count()
        for i in range(min(count, 10)):
            try:
                text = await hour_min_locator.nth(i).inner_text(timeout=2000)
                m = re.search(r'(\d+)\s*時間\s*(\d+)\s*分', text)
                if m:
                    val = int(m.group(1)) * 60 + int(m.group(2))
                    if 2 <= val <= 150:
                        times_found.append(val)
            except Exception:
                continue

        # "XX分" パターン
        min_locator = page.locator("text=/^\\d{1,3}\\s*分$/")
        count = await min_locator.count()
        for i in range(min(count, 20)):
            try:
                text = (await min_locator.nth(i).inner_text(timeout=2000)).strip()
                m = re.match(r'^(\d{1,3})\s*分$', text)
                if m:
                    val = int(m.group(1))
                    if 2 <= val <= 150:
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
                    if 2 <= val <= 150:
                        times_found.append(val)
                    continue
                m = re.match(r'^(\d{1,3})\s*分$', line)
                if m:
                    val = int(m.group(1))
                    if 2 <= val <= 150:
                        times_found.append(val)
        except Exception:
            pass

    if not times_found:
        try:
            full_text = await page.inner_text("body")
            for m in re.finditer(r'(\d{1,3})\s*分', full_text):
                val = int(m.group(1))
                if 2 <= val <= 150:
                    times_found.append(val)
        except Exception:
            pass

    if not times_found:
        return None

    return min(times_found)


async def check_no_route(page: Page) -> bool:
    """ルートが見つからない場合を検出する。"""
    try:
        text = await page.inner_text("body")
        no_route_patterns = [
            "ルートが見つかりません",
            "経路が見つかりません",
            "この区間の経路は",
            "Sorry, we could not calculate",
            "No routes found",
            "can't find a way",
        ]
        return any(p in text for p in no_route_patterns)
    except Exception:
        return False


# ---------------------------------------------------------------------------
# ワーカー（並列処理用）
# ---------------------------------------------------------------------------

async def _worker(
    worker_id: int,
    browser: Browser,
    work_items_by_office: dict[str, list[str]],
    results: dict,
    original_data: dict,
    counter: dict,
    lock: asyncio.Lock,
) -> list[tuple[str, str]]:
    """
    1つのワーカーが割り当てられた駅を処理する。

    各オフィスについて:
    1. 最初の駅で完全セットアップ（URL遷移 + 到着8:30設定）
    2. 以降の駅は出発地入力欄を書き換えて再検索（到着時刻を維持）
    """
    tag = f"[W{worker_id}]"
    context = await browser.new_context(
        locale="ja-JP",
        timezone_id="Asia/Tokyo",
        viewport={"width": 1280, "height": 900},
    )
    page = await context.new_page()

    # Cookie 同意処理
    await page.goto("https://www.google.com/maps", timeout=30000)
    await asyncio.sleep(2)
    await handle_consent(page)

    failed: list[tuple[str, str]] = []
    consecutive_failures = 0

    for office_key, stations in work_items_by_office.items():
        office = OFFICES[office_key]
        is_first_for_office = True

        for station in stations:
            # 既に処理済みならスキップ
            async with lock:
                if station in results.get(office_key, {}):
                    continue
                counter["done"] += 1
                current = counter["done"]
                total = counter["total"]

            prefix = f"[{current}/{total}]"
            success = False

            for attempt in range(1, MAX_RETRIES + 1):
                try:
                    print(
                        f"{tag}{prefix} {station} → {office['name']} ",
                        end="", flush=True,
                    )

                    if is_first_for_office:
                        # 最初の駅: URL遷移 + 到着8:30設定
                        url = build_basic_transit_url(station, office)
                        await page.goto(url, timeout=30000)
                        ok = await set_arrival_time_830(page)
                        if not ok:
                            print("→ 到着設定失敗 ✗")
                            break
                        is_first_for_office = False
                    else:
                        # 2駅目以降: 出発地を変更して再検索
                        ok = await change_origin(page, station)
                        if not ok:
                            # フォールバック: URL遷移で再試行
                            url = build_basic_transit_url(station, office)
                            await page.goto(url, timeout=30000)
                            # 到着時刻を再設定
                            ok = await set_arrival_time_830(page)
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
                            results[office_key][station] = time_min
                            rp = RESULTS_DIR / f"audit_{office_key}.json"
                            with open(rp, "w", encoding="utf-8") as f:
                                json.dump(
                                    results[office_key], f,
                                    ensure_ascii=False, indent=2,
                                )

                        old = original_data.get(office_key, {}).get(station)
                        diff_str = ""
                        if old is not None:
                            diff = time_min - old
                            if diff != 0:
                                diff_str = (
                                    f" (現在値{old}分, "
                                    f"差{'+' if diff > 0 else ''}{diff})"
                                )
                        print(f"→ {time_min}分{diff_str} ✓")
                        success = True
                        consecutive_failures = 0
                        break
                    else:
                        if attempt < MAX_RETRIES:
                            print(
                                f"取得失敗 (リトライ {attempt}/{MAX_RETRIES})"
                            )
                            # リトライ時はURL遷移で再試行
                            is_first_for_office = True
                            await asyncio.sleep(ERROR_DELAY)
                        else:
                            print("取得失敗 ✗")

                except Exception as e:
                    if attempt < MAX_RETRIES:
                        print(f"エラー (リトライ {attempt}/{MAX_RETRIES})")
                        is_first_for_office = True
                        await asyncio.sleep(ERROR_DELAY)
                    else:
                        print(f"エラー: {e} ✗")

            if not success:
                failed.append((station, office_key))
                consecutive_failures += 1
                if consecutive_failures >= 5:
                    print(f"\n{tag} ⚠ 5回連続失敗。30秒待機...")
                    await asyncio.sleep(30)
                    consecutive_failures = 0
                    is_first_for_office = True

            # レート制限回避のランダム待機
            delay = random.uniform(MIN_DELAY, MAX_DELAY)
            await asyncio.sleep(delay)

    await context.close()
    return failed


# ---------------------------------------------------------------------------
# メイン処理
# ---------------------------------------------------------------------------

async def run_audit(
    office_filter: Optional[str] = None,
    test_station: Optional[str] = None,
    dry_run: bool = False,
    num_workers: int = 1,
) -> None:
    """全駅の通勤時間を自動取得する。"""
    year, month, day = next_weekday_date()
    arrival_str = f"{year}-{month:02d}-{day:02d} 08:30"

    # 駅名ロード
    all_stations: set[str] = set()
    original_data: dict[str, dict[str, int]] = {}
    for key in OFFICES:
        path = DATA_DIR / f"commute_{key}.json"
        if path.exists():
            with open(path, "r", encoding="utf-8") as f:
                original_data[key] = json.load(f)
                all_stations.update(original_data[key].keys())
        else:
            original_data[key] = {}

    if test_station:
        stations = [test_station]
    else:
        stations = sorted(all_stations)

    offices_to_check = {
        k: v for k, v in OFFICES.items()
        if not office_filter or k == office_filter
    }

    # 既存結果ロード（レジューム用）
    RESULTS_DIR.mkdir(exist_ok=True)
    results: dict[str, dict[str, int]] = {}
    for key in offices_to_check:
        results_path = RESULTS_DIR / f"audit_{key}.json"
        if results_path.exists() and not test_station:
            with open(results_path, "r", encoding="utf-8") as f:
                results[key] = json.load(f)
        else:
            results[key] = {}

    # 統計
    total = len(stations) * len(offices_to_check)
    already_done = sum(
        sum(1 for s in stations if s in results.get(k, {}))
        for k in offices_to_check
    )
    remaining = total - already_done

    # ワーカー数の調整
    actual_workers = max(1, min(num_workers, remaining))
    # 出発地変更方式は URL 遷移より速い（~8秒/駅 → ~5秒/駅）
    est_per_item = 5.0 / actual_workers
    est_min = int(remaining * est_per_item) // 60
    est_sec = int(remaining * est_per_item) % 60

    print("=" * 60)
    print("  通勤時間 自動取得ツール")
    print("=" * 60)
    print(f"  到着時刻:     {arrival_str} JST（arrive by）")
    print(f"  対象:         {len(stations)} 駅 × {len(offices_to_check)} オフィス = {total} 件")
    print(f"  完了済み:     {already_done} 件")
    print(f"  残り:         {remaining} 件")
    print(f"  ワーカー数:   {actual_workers}")
    print(f"  推定所要時間: 約{est_min}分{est_sec}秒")
    print("=" * 60)
    print()

    if dry_run:
        _show_diff(results, original_data, offices_to_check)
        return

    if remaining == 0:
        print("✅ 全て完了済みです。--reset で最初からやり直せます。")
        _show_diff(results, original_data, offices_to_check)
        return

    # ブラウザ起動
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=False,
            args=["--lang=ja"],
        )

        # 作業リスト構築（オフィスごとにグループ化）
        # 各ワーカーにオフィス×駅を割り当て
        work_by_office: dict[str, list[str]] = defaultdict(list)
        for s in stations:
            for k in offices_to_check:
                if s not in results.get(k, {}):
                    work_by_office[k].append(s)

        # ワーカーに分配（各オフィスの駅をラウンドロビンで分配）
        worker_assignments: list[dict[str, list[str]]] = [
            defaultdict(list) for _ in range(actual_workers)
        ]
        for office_key, station_list in work_by_office.items():
            for i, station in enumerate(station_list):
                w = i % actual_workers
                worker_assignments[w][office_key].append(station)

        counter = {"done": already_done, "total": total}
        lock = asyncio.Lock()

        print(
            f"{len(sum(work_by_office.values(), []))} 件を "
            f"{actual_workers} ワーカーで並列処理中..."
        )
        print(
            "方式: 出発地入力欄書き換え（到着時刻設定を維持）"
        )
        print()

        # ワーカー起動
        tasks = [
            _worker(
                i, browser, dict(assignment),
                results, original_data, counter, lock,
            )
            for i, assignment in enumerate(worker_assignments)
            if any(assignment.values())
        ]

        failed_lists = await asyncio.gather(*tasks)
        failed = [item for sublist in failed_lists for item in sublist]

        await browser.close()

    # 結果表示
    print()
    _show_summary(results, original_data, offices_to_check, failed, stations)

    # JSON ファイル更新
    if not test_station:
        _apply_results(results, original_data, offices_to_check)


# ---------------------------------------------------------------------------
# 結果表示・適用
# ---------------------------------------------------------------------------

def _show_diff(
    results: dict, original: dict, offices: dict
) -> None:
    """現在の結果と元データの差分を表示する。"""
    for key in offices:
        if key not in results or not results[key]:
            continue
        print(f"\n--- {OFFICES[key]['name']} ---")
        changes = 0
        for station in sorted(results[key]):
            new_val = results[key][station]
            old_val = original.get(key, {}).get(station)
            if old_val is None:
                print(f"  + {station}: {new_val}分 (新規)")
                changes += 1
            elif old_val != new_val:
                diff = new_val - old_val
                print(
                    f"  Δ {station}: {old_val}分 → {new_val}分 "
                    f"({'+' if diff > 0 else ''}{diff})"
                )
                changes += 1
        print(f"  変更: {changes} 件")


def _show_summary(
    results: dict,
    original: dict,
    offices: dict,
    failed: list,
    stations: list,
) -> None:
    """結果サマリーを表示する。"""
    print("=" * 60)
    print("  結果サマリー")
    print("=" * 60)
    for key in offices:
        count = len(results.get(key, {}))
        changes = sum(
            1
            for s, v in results.get(key, {}).items()
            if original.get(key, {}).get(s) != v
        )
        print(
            f"  {OFFICES[key]['name']}: "
            f"{count}/{len(stations)} 駅取得, {changes} 件変更"
        )

    if failed:
        print(f"\n  失敗した駅 ({len(failed)} 件):")
        for station, key in failed:
            print(f"    - {station} → {OFFICES[key]['name']}")
    print()


def _apply_results(
    results: dict, original: dict, offices: dict
) -> None:
    """取得結果を commute_*.json に適用する。"""
    for key in offices:
        if key not in results or not results[key]:
            continue

        merged = {**original.get(key, {}), **results[key]}
        sorted_data = dict(sorted(merged.items(), key=lambda x: x[1]))

        output = DATA_DIR / f"commute_{key}.json"

        backup = DATA_DIR / f"commute_{key}.backup.json"
        if output.exists():
            shutil.copy2(output, backup)

        with open(output, "w", encoding="utf-8") as f:
            json.dump(sorted_data, f, ensure_ascii=False, indent=2)
            f.write("\n")

        changes = sum(
            1
            for s, v in results[key].items()
            if original.get(key, {}).get(s) != v
        )
        print(f"✅ {output.name} を更新しました ({changes} 件変更)")
        print(f"   バックアップ: {backup.name}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description="通勤時間の自動取得ツール")
    ap.add_argument(
        "--office",
        choices=["playground", "m3career"],
        help="特定のオフィスのみ処理",
    )
    ap.add_argument(
        "--test",
        metavar="STATION",
        help="1駅だけテスト取得（例: --test 品川）",
    )
    ap.add_argument(
        "--workers",
        type=int,
        default=1,
        help="並列ワーカー数（デフォルト: 1、推奨: 3）",
    )
    ap.add_argument(
        "--reset",
        action="store_true",
        help="前回の途中結果をリセットして最初から",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="取得せず現在の結果と元データの差分だけ表示",
    )
    args = ap.parse_args()

    if args.reset and RESULTS_DIR.exists():
        shutil.rmtree(RESULTS_DIR)
        print("前回の結果をリセットしました。\n")

    asyncio.run(
        run_audit(
            office_filter=args.office,
            test_station=args.test,
            dry_run=args.dry_run,
            num_workers=args.workers,
        )
    )


if __name__ == "__main__":
    main()
