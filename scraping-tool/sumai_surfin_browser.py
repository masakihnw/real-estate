"""
住まいサーフィン ブラウザ自動化モジュール（Playwright ベース）

requests + BeautifulSoup では取得できない、ボタンクリック・フォーム操作が
必要なデータを Playwright (headless Chromium) で取得する。

対象データ:
  1. 中古: 「販売価格が割安か判定する」→ 住戸ごとの割安/割高判定
  2. 新築: 「10年後予測詳細を見る」→ カスタムパラメータでシミュレーション再計算

使い方:
  python3 sumai_surfin_browser.py --input results/latest.json --output results/latest.json --property-type chuko
  python3 sumai_surfin_browser.py --input results/latest_shinchiku.json --output results/latest_shinchiku.json --property-type shinchiku

環境変数:
  SUMAI_USER  -- ログインユーザー名
  SUMAI_PASS  -- ログインパスワード

依存:
  pip install playwright && playwright install chromium
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Optional

try:
    from playwright.sync_api import sync_playwright, Page, Browser, BrowserContext
    PLAYWRIGHT_AVAILABLE = True
except ImportError:
    PLAYWRIGHT_AVAILABLE = False

from bs4 import BeautifulSoup

# ──────────────────────────── 定数 ────────────────────────────

BASE_URL = "https://www.sumai-surfin.com"
LOGIN_URL = "https://account.sumai-surfin.com/login"

# ページ操作のタイムアウト（ms）
NAV_TIMEOUT = 30_000
ACTION_TIMEOUT = 15_000

# ページ間のディレイ（秒）
PAGE_DELAY = 2.0

# 新築シミュレーションのデフォルトパラメータ
DEFAULT_SIM_PRICE = 9500       # 万円
DEFAULT_SIM_RATE = 0.8         # %
DEFAULT_SIM_TERM = 50          # 年
DEFAULT_SIM_DOWN_PAYMENT = 0   # 万円


# ──────────────────────────── ログイン ────────────────────────────

def browser_login(page: "Page", user: str, password: str) -> bool:
    """Playwright でブラウザログインを行う。

    Returns:
        True: ログイン成功
        False: ログイン失敗
    """
    try:
        page.goto(LOGIN_URL, wait_until="networkidle", timeout=NAV_TIMEOUT)
        time.sleep(1)

        # ── ユーザー名フィールドを探す ──
        # 戦略1: type=text の input（name に login を含むもの優先）
        username_input = None
        password_input = None

        # name 属性で探す（既知のフィールド名）
        for selector in [
            'input[name="login_name"]',
            'input[name="username"]',
            'input[name="email"]',
            'input[type="text"]',
            'input[type="email"]',
        ]:
            loc = page.locator(selector).first
            if loc.count() > 0 and loc.is_visible():
                username_input = loc
                break

        for selector in [
            'input[name="login_password"]',
            'input[name="password"]',
            'input[type="password"]',
        ]:
            loc = page.locator(selector).first
            if loc.count() > 0 and loc.is_visible():
                password_input = loc
                break

        if not username_input or not password_input:
            print("ブラウザログイン: 入力フィールドが見つかりません", file=sys.stderr)
            return False

        # ── 入力 ──
        username_input.fill(user)
        time.sleep(0.3)
        password_input.fill(password)
        time.sleep(0.3)

        # ── ログインボタンをクリック ──
        login_btn = None
        for selector in [
            'button[type="submit"]',
            'input[type="submit"]',
            'button:has-text("ログイン")',
            'a:has-text("ログイン")',
        ]:
            loc = page.locator(selector).first
            if loc.count() > 0 and loc.is_visible():
                login_btn = loc
                break

        if not login_btn:
            # フォールバック: Enter キーで送信
            password_input.press("Enter")
        else:
            login_btn.click()

        # ── ログイン完了を待つ ──
        page.wait_for_load_state("networkidle", timeout=NAV_TIMEOUT)
        time.sleep(2)

        # リダイレクト先が SSO フローの場合、追加のナビゲーションが必要
        # www.sumai-surfin.com/member/ にアクセスして SSO を確立
        page.goto(f"{BASE_URL}/member/", wait_until="networkidle", timeout=NAV_TIMEOUT)
        time.sleep(1)

        # ── 成功判定 ──
        content = page.content()
        if "ログアウト" in content or "mypage" in page.url:
            print("ブラウザログイン: 成功", file=sys.stderr)
            return True

        # フォールバック: 検索ページで確認
        page.goto(f"{BASE_URL}/search/", wait_until="networkidle", timeout=NAV_TIMEOUT)
        content = page.content()
        if "ログアウト" in content:
            print("ブラウザログイン: 成功（検索ページで確認）", file=sys.stderr)
            return True

        print("ブラウザログイン: 失敗（ログアウトリンクが見つかりません）", file=sys.stderr)
        return False

    except Exception as e:
        print(f"ブラウザログイン: エラー: {e}", file=sys.stderr)
        return False


# ──────────────────────────── 中古: 販売価格割安判定 ────────────────────────────

def extract_chuko_price_judgments(page: "Page", url: str) -> Optional[list[dict]]:
    """中古物件の「販売価格が割安か判定する」ボタンをクリックし、
    住戸ごとの割安/割高判定を取得する。

    Returns:
        判定データのリスト。取得失敗時は None。
        [
          {
            "unit": "3階/14階建",
            "price_man": 5980,
            "m2_price": 78,
            "layout": "2LDK",
            "area_m2": 76.24,
            "direction": "南",
            "oki_price_man": 6200,
            "difference_man": -220,
            "judgment": "割安"
          }
        ]
    """
    try:
        page.goto(url, wait_until="networkidle", timeout=NAV_TIMEOUT)
        time.sleep(PAGE_DELAY)

        # ── 「販売価格が割安か判定する」ボタンを探してクリック ──
        judge_btn = _find_clickable(page, [
            'button:has-text("販売価格が割安か判定")',
            'a:has-text("販売価格が割安か判定")',
            'input[value*="販売価格が割安か判定"]',
            ':text("販売価格が割安か判定する")',
        ])

        if not judge_btn:
            print(f"  [Browser] 割安判定ボタンが見つかりません: {url}", file=sys.stderr)
            return None

        judge_btn.click()

        # ── ログインポップアップの処理 ──
        time.sleep(2)
        _handle_login_popup(page)

        # ── 判定結果の表示を待つ ──
        # 判定後、テーブルが更新される。「割安」「割高」「適正」のいずれかが表示されるまで待つ
        try:
            page.wait_for_function(
                """() => {
                    const text = document.body.innerText;
                    return text.includes('割安') || text.includes('割高') || text.includes('適正');
                }""",
                timeout=ACTION_TIMEOUT,
            )
        except Exception:
            # タイムアウトしても続行（既にデータがある場合）
            pass

        time.sleep(1)

        # ── HTML を取得して解析 ──
        html = page.content()
        soup = BeautifulSoup(html, "lxml")

        return _parse_price_judgment_table(soup, html)

    except Exception as e:
        print(f"  [Browser] 中古割安判定エラー ({url}): {e}", file=sys.stderr)
        return None


def _parse_price_judgment_table(soup: BeautifulSoup, html: str) -> Optional[list[dict]]:
    """割安判定テーブルから住戸ごとのデータを抽出する。"""
    results: list[dict] = []

    # テーブルを探す: 「販売住戸」「販売価格」等のヘッダーを含むテーブル
    tables = soup.find_all("table")

    for table in tables:
        headers_text = table.get_text()
        # 割安判定テーブルのヘッダー特徴: 「販売住戸」「販売価格」「沖式」
        if "販売住戸" not in headers_text and "販売価格" not in headers_text:
            continue

        rows = table.find_all("tr")
        if len(rows) < 2:
            continue

        # ヘッダー行からカラムインデックスを特定
        header_row = rows[0]
        header_cells = header_row.find_all(["th", "td"])
        col_map = _build_column_map(header_cells)

        # データ行をパース
        for row in rows[1:]:
            cells = row.find_all(["td", "th"])
            if len(cells) < 3:
                continue

            entry: dict = {}

            # 販売住戸（階/総階建）
            if "unit" in col_map and col_map["unit"] < len(cells):
                entry["unit"] = cells[col_map["unit"]].get_text(strip=True)

            # 販売価格（万円）
            if "price" in col_map and col_map["price"] < len(cells):
                price_text = cells[col_map["price"]].get_text(strip=True)
                m = re.search(r"([\d,]+)\s*万", price_text)
                if m:
                    entry["price_man"] = int(m.group(1).replace(",", ""))

            # m²単価
            if "m2_price" in col_map and col_map["m2_price"] < len(cells):
                m2_text = cells[col_map["m2_price"]].get_text(strip=True)
                m = re.search(r"([\d,.]+)\s*万", m2_text)
                if m:
                    try:
                        entry["m2_price"] = round(float(m.group(1).replace(",", "")))
                    except ValueError:
                        pass

            # 間取り
            if "layout" in col_map and col_map["layout"] < len(cells):
                entry["layout"] = cells[col_map["layout"]].get_text(strip=True)

            # 面積（㎡）
            if "area" in col_map and col_map["area"] < len(cells):
                area_text = cells[col_map["area"]].get_text(strip=True)
                m = re.search(r"([\d.]+)", area_text)
                if m:
                    try:
                        entry["area_m2"] = float(m.group(1))
                    except ValueError:
                        pass

            # 向き
            if "direction" in col_map and col_map["direction"] < len(cells):
                entry["direction"] = cells[col_map["direction"]].get_text(strip=True)

            # 沖式中古時価（万円）— 判定クリック後に表示される列
            if "oki_price" in col_map and col_map["oki_price"] < len(cells):
                oki_text = cells[col_map["oki_price"]].get_text(strip=True)
                m = re.search(r"([\d,]+)\s*万", oki_text)
                if m:
                    entry["oki_price_man"] = int(m.group(1).replace(",", ""))

            # 差額（万円）
            if "difference" in col_map and col_map["difference"] < len(cells):
                diff_text = cells[col_map["difference"]].get_text(strip=True)
                m = re.search(r"([+-]?[\d,]+)\s*万", diff_text)
                if m:
                    entry["difference_man"] = int(m.group(1).replace(",", ""))

            # 判定（割安/割高/適正）
            if "judgment" in col_map and col_map["judgment"] < len(cells):
                j_text = cells[col_map["judgment"]].get_text(strip=True)
                entry["judgment"] = j_text
            else:
                # テーブル外の判定テキストをフォールバックで探す
                row_text = row.get_text()
                for kw in ("やや割安", "やや割高", "割安", "割高", "適正"):
                    if kw in row_text:
                        entry["judgment"] = kw
                        break

            # 販売価格と沖式時価があれば差額を算出
            if "difference_man" not in entry and "price_man" in entry and "oki_price_man" in entry:
                entry["difference_man"] = entry["price_man"] - entry["oki_price_man"]

            if entry.get("price_man") or entry.get("judgment"):
                results.append(entry)

        if results:
            break  # 最初のマッチするテーブルのみ

    # テーブルが見つからなかった場合: regex フォールバック
    if not results:
        results = _parse_price_judgment_regex(html)

    return results if results else None


def _build_column_map(header_cells: list) -> dict[str, int]:
    """ヘッダーセルからカラム名→インデックスのマッピングを構築する。"""
    col_map: dict[str, int] = {}
    for i, cell in enumerate(header_cells):
        text = cell.get_text(strip=True)
        if "販売住戸" in text or "階" in text:
            col_map.setdefault("unit", i)
        if "販売価格" in text and "m" not in text.lower() and "㎡" not in text:
            col_map.setdefault("price", i)
        if "m2" in text.lower() or "㎡" in text or "m²" in text:
            if "単価" in text:
                col_map.setdefault("m2_price", i)
        if "間取り" in text:
            col_map.setdefault("layout", i)
        if "面積" in text or "専有" in text:
            col_map.setdefault("area", i)
        if "向き" in text or "方位" in text:
            col_map.setdefault("direction", i)
        if "沖式" in text or "時価" in text:
            col_map.setdefault("oki_price", i)
        if "差額" in text:
            col_map.setdefault("difference", i)
        if "判定" in text and "固定" not in text:
            col_map.setdefault("judgment", i)
    return col_map


def _parse_price_judgment_regex(html: str) -> list[dict]:
    """正規表現による割安判定データのフォールバック抽出。"""
    results: list[dict] = []

    # 「X階/Y階建」のパターンで住戸ブロックを検出し、
    # 近傍から価格・判定を抽出
    unit_pattern = re.compile(
        r"(\d+階\s*/?\s*\d+階建?).{0,500}?"
        r"([\d,]+)\s*万円.{0,300}?"
        r"(やや割安|やや割高|割安|割高|適正)",
        re.DOTALL,
    )
    for m in unit_pattern.finditer(html):
        entry: dict = {
            "unit": m.group(1).strip(),
            "price_man": int(m.group(2).replace(",", "")),
            "judgment": m.group(3),
        }
        results.append(entry)

    return results


# ──────────────────────────── 新築: カスタムシミュレーション ────────────────────────────

def extract_shinchiku_custom_simulation(
    page: "Page",
    url: str,
    price: int = DEFAULT_SIM_PRICE,
    rate: float = DEFAULT_SIM_RATE,
    term: int = DEFAULT_SIM_TERM,
    down_payment: int = DEFAULT_SIM_DOWN_PAYMENT,
) -> Optional[dict]:
    """新築物件の「10年後予測詳細を見る」をクリックし、
    カスタムパラメータでシミュレーションを再計算する。

    Args:
        page: Playwright Page オブジェクト
        url: 物件詳細ページの URL
        price: 希望住戸の価格（万円）
        rate: 金利（%）
        term: 返済期間（年）
        down_payment: 頭金（万円）

    Returns:
        シミュレーションデータの dict。取得失敗時は None。
        {
            "ss_sim_best_5yr": 7344,
            "ss_sim_best_10yr": 7788,
            "ss_sim_standard_5yr": 6744,
            "ss_sim_standard_10yr": 6588,
            "ss_sim_worst_5yr": 6144,
            "ss_sim_worst_10yr": 5388,
            "ss_loan_balance_5yr": 5395,
            "ss_loan_balance_10yr": 4757,
            "ss_gain_best_5yr": 1949,
            "ss_gain_best_10yr": 3031,
            ...
            "ss_sim_base_price": 9500,
        }
    """
    try:
        page.goto(url, wait_until="networkidle", timeout=NAV_TIMEOUT)
        time.sleep(PAGE_DELAY)

        # ── Step 1: 「10年後予測詳細を見る」ボタンをクリック ──
        forecast_btn = _find_clickable(page, [
            'button:has-text("10年後予測詳細を見る")',
            'a:has-text("10年後予測詳細を見る")',
            ':text("10年後予測詳細を見る")',
            'a:has-text("10年後予測")',
        ])

        if not forecast_btn:
            print(f"  [Browser] 10年後予測ボタンが見つかりません: {url}", file=sys.stderr)
            return None

        forecast_btn.click()

        # ── ログインポップアップ/リダイレクトの処理 ──
        time.sleep(2)
        _handle_login_popup(page)

        # フォームが表示されるまで待つ
        try:
            page.wait_for_function(
                """() => {
                    const inputs = document.querySelectorAll('input');
                    return inputs.length > 3;
                }""",
                timeout=ACTION_TIMEOUT,
            )
        except Exception:
            pass

        time.sleep(1)

        # ── Step 2: フォームにカスタムパラメータを入力 ──
        _fill_simulation_form(page, price, rate, term, down_payment)

        # ── Step 3: 値上がりシミュレーションの再計算ボタンをクリック ──
        recalc_btns = _find_all_clickable(page, [
            'button:has-text("再計算")',
            'button:has-text("計算")',
            'input[type="submit"][value*="計算"]',
            'a:has-text("再計算")',
        ])

        if recalc_btns:
            # 最初の再計算ボタン（値上がりシミュレーション用）
            recalc_btns[0].click()
            time.sleep(3)

            # 含み益シミュレーションの再計算ボタンがあればクリック
            if len(recalc_btns) > 1:
                recalc_btns[1].click()
                time.sleep(3)
        else:
            # ボタンが見つからない場合、フォーム送信を試行
            page.keyboard.press("Enter")
            time.sleep(3)

        # ── Step 4: 結果のHTMLを取得して解析 ──
        html = page.content()
        soup = BeautifulSoup(html, "lxml")

        result = _parse_simulation_tables(soup, html)
        if result:
            result["ss_sim_base_price"] = price

        return result if result else None

    except Exception as e:
        print(f"  [Browser] 新築シミュレーションエラー ({url}): {e}", file=sys.stderr)
        return None


def _fill_simulation_form(
    page: "Page", price: int, rate: float, term: int, down_payment: int
) -> None:
    """シミュレーションフォームにパラメータを入力する。"""

    # 入力フィールドの候補（name/label のパターン）
    field_patterns = [
        # (フィールド名パターン, 値)
        (["price", "kakaku", "価格"], str(price)),
        (["rate", "kinri", "金利"], str(rate)),
        (["term", "year", "kikan", "期間", "返済"], str(term)),
        (["down", "atama", "頭金"], str(down_payment)),
    ]

    for patterns, value in field_patterns:
        filled = False
        for pat in patterns:
            # name 属性で検索
            for selector in [
                f'input[name*="{pat}" i]',
                f'input[id*="{pat}" i]',
                f'input[placeholder*="{pat}"]',
            ]:
                try:
                    loc = page.locator(selector).first
                    if loc.count() > 0 and loc.is_visible():
                        loc.fill(value)
                        filled = True
                        break
                except Exception:
                    continue
            if filled:
                break

        if not filled:
            # ラベルテキストからフィールドを探す
            for pat in patterns:
                try:
                    label = page.locator(f'label:has-text("{pat}")').first
                    if label.count() > 0:
                        for_id = label.get_attribute("for")
                        if for_id:
                            inp = page.locator(f"#{for_id}")
                            if inp.count() > 0:
                                inp.fill(value)
                                filled = True
                                break
                except Exception:
                    continue

    time.sleep(0.5)


def _parse_simulation_tables(soup: BeautifulSoup, html: str) -> Optional[dict]:
    """シミュレーション結果テーブルから値上がり + 含み益 + ローン残高を抽出する。"""
    result: dict = {}

    tables = soup.find_all("table")

    for table in tables:
        text = table.get_text()

        # ── 値上がりシミュレーションテーブル ──
        if ("ベストケース" in text or "標準ケース" in text) and "含み益" not in text:
            _parse_sim_table_rows(table, result, prefix="ss_sim")

        # ── 含み益シミュレーションテーブル ──
        if "含み益" in text and ("ベストケース" in text or "標準ケース" in text):
            _parse_sim_table_rows(table, result, prefix="ss_gain")

    # テーブルが見つからなかった場合: 正規表現フォールバック
    if not result:
        result = _parse_simulation_regex(html)

    # ローン残高（テーブルから抽出 or 正規表現）
    if "ss_loan_balance_5yr" not in result:
        _extract_loan_balance(soup, html, result)

    # バリデーション
    validated: dict = {}
    for k, v in result.items():
        if isinstance(v, int) and v < 100 and "rate" not in k:
            print(f"  [Browser] シミュレーション値バリデーション失敗: {k}={v}", file=sys.stderr)
            continue
        validated[k] = v

    return validated if validated else None


def _parse_sim_table_rows(table, result: dict, prefix: str) -> None:
    """シミュレーションテーブルの行からデータを抽出する。"""
    rows = table.find_all("tr")
    for row in rows:
        cells = row.find_all(["td", "th"])
        if len(cells) < 3:
            continue

        row_text = cells[0].get_text(strip=True)

        case_key = None
        if "ベスト" in row_text:
            case_key = "best"
        elif "標準" in row_text:
            case_key = "standard"
        elif "ワースト" in row_text:
            case_key = "worst"
        elif "ローン残高" in row_text:
            case_key = "__loan__"
        else:
            continue

        for idx, suffix in [(1, "5yr"), (2, "10yr")]:
            if idx < len(cells):
                val_text = cells[idx].get_text(strip=True)
                num = re.search(r"([+-]?[\d,]+)\s*万", val_text)
                if num:
                    val = int(num.group(1).replace(",", "").replace("+", ""))
                    if case_key == "__loan__":
                        result[f"ss_loan_balance_{suffix}"] = abs(val)
                    else:
                        result[f"{prefix}_{case_key}_{suffix}"] = val


def _parse_simulation_regex(html: str) -> dict:
    """正規表現によるシミュレーションデータのフォールバック抽出。"""
    result: dict = {}

    # 値上がりシミュレーション
    case_patterns = {
        "best": r"ベストケース",
        "standard": r"標準ケース",
        "worst": r"ワーストケース",
    }
    for case_key, case_pat in case_patterns.items():
        m = re.search(
            case_pat + r".{0,500}?([\d,]+)\s*万円.{0,200}?([\d,]+)\s*万円",
            html, re.DOTALL,
        )
        if m:
            val_5yr = int(m.group(1).replace(",", ""))
            val_10yr = int(m.group(2).replace(",", ""))
            if val_5yr >= 500 and val_10yr >= 500:
                result[f"ss_sim_{case_key}_5yr"] = val_5yr
                result[f"ss_sim_{case_key}_10yr"] = val_10yr

    return result


def _extract_loan_balance(soup: BeautifulSoup, html: str, result: dict) -> None:
    """ローン残高を抽出する。"""
    # テーブルから
    for table in soup.find_all("table"):
        for row in table.find_all("tr"):
            cells = row.find_all(["td", "th"])
            if len(cells) >= 3 and "ローン残高" in cells[0].get_text():
                for idx, suffix in [(1, "5yr"), (2, "10yr")]:
                    if idx < len(cells):
                        val_text = cells[idx].get_text(strip=True)
                        num = re.search(r"([\d,]+)\s*万", val_text)
                        if num:
                            result[f"ss_loan_balance_{suffix}"] = int(
                                num.group(1).replace(",", "")
                            )
                return

    # 正規表現フォールバック
    m = re.search(
        r"ローン残高.{0,300}?([\d,]+)\s*万円.{0,200}?([\d,]+)\s*万円",
        html, re.DOTALL,
    )
    if m:
        result["ss_loan_balance_5yr"] = int(m.group(1).replace(",", ""))
        result["ss_loan_balance_10yr"] = int(m.group(2).replace(",", ""))


# ──────────────────────────── 共通ヘルパー ────────────────────────────

def _find_clickable(page: "Page", selectors: list[str]):
    """複数のセレクタ候補から最初に見つかるクリック可能な要素を返す。"""
    for selector in selectors:
        try:
            loc = page.locator(selector).first
            if loc.count() > 0 and loc.is_visible():
                return loc
        except Exception:
            continue
    return None


def _find_all_clickable(page: "Page", selectors: list[str]) -> list:
    """複数のセレクタ候補から全てのクリック可能な要素を返す。"""
    results = []
    seen_texts: set[str] = set()
    for selector in selectors:
        try:
            locs = page.locator(selector)
            for i in range(locs.count()):
                loc = locs.nth(i)
                if loc.is_visible():
                    text = loc.text_content() or ""
                    if text not in seen_texts:
                        results.append(loc)
                        seen_texts.add(text)
        except Exception:
            continue
    return results


def _handle_login_popup(page: "Page") -> None:
    """ログインポップアップが表示された場合、閉じる or ログインフォームを処理する。

    ※ ブラウザログインが先に完了していれば、ポップアップは出ないはず。
       出た場合はセッションが切れているため、再ログインを試みる。
    """
    try:
        # ポップアップの閉じるボタン
        close_btn = page.locator('[class*="close"], [class*="dismiss"], button:has-text("閉じる")').first
        if close_btn.count() > 0 and close_btn.is_visible():
            close_btn.click()
            time.sleep(1)
    except Exception:
        pass


# ──────────────────────────── ユーティリティ ────────────────────────────


def _pick_value_judgment(
    judgments: list[dict],
    listing_price_man: Optional[int] = None,
) -> Optional[str]:
    """住戸ごとの判定リストから、物件全体の ss_value_judgment を導出する。

    ロジック:
      1. listing_price_man（SUUMO等の掲載価格）に最も近い住戸の judgment を採用
      2. 掲載価格がない/マッチしない場合は最初の住戸の judgment を使用
    """
    if not judgments:
        return None

    # 全住戸の判定を持つエントリだけ対象
    with_judgment = [j for j in judgments if j.get("judgment")]
    if not with_judgment:
        return None

    # 住戸が1つなら即採用
    if len(with_judgment) == 1:
        return with_judgment[0]["judgment"]

    # 掲載価格に最も近い住戸を探す
    if listing_price_man is not None:
        best = None
        best_diff = float("inf")
        for j in with_judgment:
            unit_price = j.get("price_man")
            if unit_price is not None:
                diff = abs(unit_price - listing_price_man)
                if diff < best_diff:
                    best_diff = diff
                    best = j
        if best:
            return best["judgment"]

    # フォールバック: 最初の住戸
    return with_judgment[0]["judgment"]


# ──────────────────────────── メイン: バッチ enrichment ────────────────────────────

def browser_enrich_listings(
    input_path: str,
    output_path: str,
    property_type: str = "chuko",
    user: str = "",
    password: str = "",
    sim_price: int = DEFAULT_SIM_PRICE,
    sim_rate: float = DEFAULT_SIM_RATE,
    sim_term: int = DEFAULT_SIM_TERM,
    sim_down: int = DEFAULT_SIM_DOWN_PAYMENT,
) -> None:
    """物件 JSON の各物件にブラウザ自動化でデータを付加する。

    中古: 販売価格割安判定（ss_price_judgments）
    新築: カスタムパラメータでシミュレーション再計算（ss_sim_* を上書き）
    """
    if not PLAYWRIGHT_AVAILABLE:
        print("ブラウザ enrichment: playwright が未インストールです", file=sys.stderr)
        print("  pip install playwright && playwright install chromium", file=sys.stderr)
        return

    output_path_p = Path(output_path)

    with open(input_path, "r", encoding="utf-8") as f:
        listings = json.load(f)

    if not isinstance(listings, list):
        print("ブラウザ enrichment: 入力が配列ではありません", file=sys.stderr)
        return

    # ブラウザ enrichment の対象を絞る: ss_sumai_surfin_url がある物件のみ
    targets = [
        (i, listing) for i, listing in enumerate(listings)
        if listing.get("ss_sumai_surfin_url")
    ]

    if not targets:
        print("ブラウザ enrichment: 対象物件なし（ss_sumai_surfin_url が未設定）", file=sys.stderr)
        return

    # さらにフィルタ: まだブラウザ enrichment が済んでいない物件のみ
    if property_type == "chuko":
        targets = [
            (i, listing) for i, listing in targets
            if listing.get("ss_price_judgments") is None
        ]
    # 新築は常に再計算（カスタムパラメータの変更を想定）

    if not targets:
        print("ブラウザ enrichment: 全物件処理済み", file=sys.stderr)
        return

    print(f"ブラウザ enrichment 開始: {len(targets)}件 ({property_type})", file=sys.stderr)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent=(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            ),
            viewport={"width": 1280, "height": 800},
            locale="ja-JP",
        )
        page = context.new_page()

        # ── ログイン ──
        if not browser_login(page, user, password):
            print("ブラウザ enrichment: ログイン失敗のためスキップ", file=sys.stderr)
            browser.close()
            return

        enriched_count = 0
        error_count = 0

        for idx, (i, listing) in enumerate(targets):
            url = listing["ss_sumai_surfin_url"]
            name = listing.get("name", "???")

            try:
                if property_type == "chuko":
                    # ── 中古: 割安判定 ──
                    judgments = extract_chuko_price_judgments(page, url)
                    if judgments:
                        listing["ss_price_judgments"] = json.dumps(
                            judgments, ensure_ascii=False
                        )
                        # ── ss_value_judgment を住戸判定から導出 ──
                        # 掲載価格に最も近い住戸の判定を採用。
                        # 該当なしの場合は最初の住戸の判定を使用。
                        best_judgment = _pick_value_judgment(
                            judgments, listing.get("price_man")
                        )
                        if best_judgment:
                            listing["ss_value_judgment"] = best_judgment

                        enriched_count += 1
                        unit_count = len(judgments)
                        cheap = sum(1 for j in judgments if j.get("judgment") in ("割安", "やや割安"))
                        print(
                            f"  ✓ {name} — 割安判定: {unit_count}戸中{cheap}戸割安"
                            f" → ss_value_judgment={best_judgment or '?'}",
                            file=sys.stderr,
                        )
                    else:
                        error_count += 1
                        print(f"  ✗ {name} — 割安判定データ取得失敗", file=sys.stderr)

                else:
                    # ── 新築: カスタムシミュレーション ──
                    sim_data = extract_shinchiku_custom_simulation(
                        page, url, price=sim_price, rate=sim_rate,
                        term=sim_term, down_payment=sim_down,
                    )
                    if sim_data:
                        # 既存のシミュレーションデータを上書き
                        for k, v in sim_data.items():
                            listing[k] = v
                        enriched_count += 1
                        parts = []
                        if sim_data.get("ss_sim_standard_10yr"):
                            parts.append(f"標準10年: {sim_data['ss_sim_standard_10yr']}万")
                        if sim_data.get("ss_gain_standard_10yr"):
                            parts.append(f"含み益: {sim_data['ss_gain_standard_10yr']}万")
                        print(
                            f"  ✓ {name} — シミュレーション({sim_price}万): {', '.join(parts)}",
                            file=sys.stderr,
                        )
                    else:
                        error_count += 1
                        print(f"  ✗ {name} — シミュレーションデータ取得失敗", file=sys.stderr)

            except Exception as e:
                error_count += 1
                print(f"  ✗ {name} — エラー: {e}", file=sys.stderr)

            # 進捗表示
            if (idx + 1) % 10 == 0:
                print(
                    f"  ブラウザ進捗: {idx + 1}/{len(targets)}件 "
                    f"(成功: {enriched_count}, 失敗: {error_count})",
                    file=sys.stderr,
                )

            # ページ間のディレイ
            time.sleep(PAGE_DELAY)

        browser.close()

    # ── 出力（原子的書き込み）──
    tmp_path = output_path_p.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp_path.replace(output_path_p)

    print(
        f"ブラウザ enrichment 完了: {enriched_count}件成功, {error_count}件失敗 "
        f"({len(targets)}件中)",
        file=sys.stderr,
    )


# ──────────────────────────── CLI ────────────────────────────

def main() -> None:
    if not PLAYWRIGHT_AVAILABLE:
        print("エラー: playwright が必要です", file=sys.stderr)
        print("  pip install playwright && playwright install chromium", file=sys.stderr)
        sys.exit(1)

    ap = argparse.ArgumentParser(
        description="住まいサーフィンのブラウザ自動化 enrichment（販売価格割安判定・カスタムシミュレーション）"
    )
    ap.add_argument("--input", "-i", required=True, help="入力 JSON ファイル")
    ap.add_argument("--output", "-o", required=True, help="出力 JSON ファイル")
    ap.add_argument(
        "--property-type", choices=["chuko", "shinchiku"], default=None,
        help="物件タイプ（未指定時はファイル名から自動判定）",
    )
    ap.add_argument("--price", type=int, default=DEFAULT_SIM_PRICE,
                    help=f"シミュレーション価格（万円、デフォルト: {DEFAULT_SIM_PRICE}）")
    ap.add_argument("--rate", type=float, default=DEFAULT_SIM_RATE,
                    help=f"金利（%%、デフォルト: {DEFAULT_SIM_RATE}）")
    ap.add_argument("--term", type=int, default=DEFAULT_SIM_TERM,
                    help=f"返済期間（年、デフォルト: {DEFAULT_SIM_TERM}）")
    ap.add_argument("--down-payment", type=int, default=DEFAULT_SIM_DOWN_PAYMENT,
                    help=f"頭金（万円、デフォルト: {DEFAULT_SIM_DOWN_PAYMENT}）")
    args = ap.parse_args()

    # 物件タイプの自動判定
    if args.property_type:
        prop_type = args.property_type
    elif "shinchiku" in args.input.lower():
        prop_type = "shinchiku"
    else:
        prop_type = "chuko"

    user = os.environ.get("SUMAI_USER", "")
    password = os.environ.get("SUMAI_PASS", "")

    if not user or not password:
        print("エラー: SUMAI_USER / SUMAI_PASS が未設定です", file=sys.stderr)
        sys.exit(1)

    browser_enrich_listings(
        input_path=args.input,
        output_path=args.output,
        property_type=prop_type,
        user=user,
        password=password,
        sim_price=args.price,
        sim_rate=args.rate,
        sim_term=args.term,
        sim_down=args.down_payment,
    )


if __name__ == "__main__":
    main()
