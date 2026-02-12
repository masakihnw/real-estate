"""
住まいサーフィン (sumai-surfin.com) から物件評価データを取得し、
既存の物件 JSON を enrichment する。

使い方:
  python3 sumai_surfin_enricher.py --input results/latest.json --output results/latest.json
  python3 sumai_surfin_enricher.py --input results/latest_shinchiku.json --output results/latest_shinchiku.json

環境変数:
  SUMAI_USER  -- ログインユーザー名
  SUMAI_PASS  -- ログインパスワード
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
from urllib.parse import quote_plus  # noqa: F401 — 将来の拡張用に保持

import requests
from bs4 import BeautifulSoup

from config import REQUEST_DELAY_SEC, REQUEST_RETRIES, USER_AGENT

# ──────────────────────────── 定数 ────────────────────────────

HTTP_BACKOFF_SEC = 2

BASE_URL = "https://www.sumai-surfin.com"
LOGIN_URL = "https://account.sumai-surfin.com/login"
# 2026-02 サイトリニューアルで検索 URL が変更:
#   旧: /search/?q=NAME
#   新: /search/result/?prefecture_id=13&keyword=NAME
SEARCH_RESULT_URL = f"{BASE_URL}/search/result/"
# 東京都の prefecture_id（全物件が東京都前提）
TOKYO_PREFECTURE_ID = "13"

CACHE_PATH = Path(__file__).parent / "data" / "sumai_surfin_cache.json"

DELAY = max(REQUEST_DELAY_SEC, 1.5)  # 住まいサーフィンへは最低 1.5 秒間隔


# ──────────────────────────── セッション ────────────────────────────

def _create_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "ja,en-US;q=0.7,en;q=0.3",
    })
    return s


def _request_with_retry(session: requests.Session, method: str, url: str, **kwargs) -> Optional[requests.Response]:
    """リトライ付き HTTP リクエスト（GET/POST 共通ヘルパー）。"""
    resp = None
    for attempt in range(REQUEST_RETRIES):
        try:
            resp = session.request(method, url, timeout=30, **kwargs)
            if resp.status_code == 429:
                wait = int(resp.headers.get("Retry-After", 60))
                if attempt < REQUEST_RETRIES - 1:
                    time.sleep(wait)
                    continue
            if 500 <= resp.status_code < 600 and attempt < REQUEST_RETRIES - 1:
                time.sleep(HTTP_BACKOFF_SEC * (attempt + 1))
                continue
            resp.raise_for_status()
            break
        except requests.RequestException:
            if attempt < REQUEST_RETRIES - 1:
                time.sleep(HTTP_BACKOFF_SEC * (attempt + 1))
            else:
                raise
    return resp


def login(session: requests.Session, user: str, password: str) -> bool:
    """住まいサーフィンにログインし、セッション Cookie を取得する。

    認証フロー:
      1. account.sumai-surfin.com/login に POST → ssan Cookie 取得
      2. www.sumai-surfin.com/member/ にアクセス → OAuth authorize
         → auth code → code exchange → www 側セッション確立
    """
    try:
        # ── Step 1: ログインページを取得して CSRF トークン等を確認 ──
        resp = _request_with_retry(session, "GET", LOGIN_URL)
        if resp is None:
            return False

        soup = BeautifulSoup(resp.text, "lxml")

        # フォームの hidden input を探す
        form_data: dict[str, str] = {}
        form_tag = soup.find("form")
        if form_tag:
            for inp in form_tag.find_all("input", {"type": "hidden"}):
                name = inp.get("name", "")
                val = inp.get("value", "")
                if name:
                    form_data[name] = val

        # ユーザー名・パスワードフィールド名
        # 2026-02: サイトリニューアルで JS ベースのログインに変更された。
        # フォームタグの有無に関係なく、実際のフィールド名を使用する。
        # 検出を試みるが、失敗時は既知のフィールド名にフォールバック。
        username_field = None
        password_field = None
        # form タグ内、または form タグがなければページ全体から検出
        search_root = form_tag or soup
        for inp in search_root.find_all("input"):
            t = inp.get("type", "").lower()
            n = inp.get("name", "")
            if t == "text" and n and not username_field:
                username_field = n
            elif t == "password" and n and not password_field:
                password_field = n
        # フォールバック: 住まいサーフィンの既知フィールド名
        if not username_field:
            username_field = "login_name"
        if not password_field:
            password_field = "login_password"

        form_data[username_field] = user
        form_data[password_field] = password

        print(f"住まいサーフィン: ログイン試行 (user_field={username_field}, pass_field={password_field})", file=sys.stderr)

        # POST 先
        action = LOGIN_URL
        if form_tag and form_tag.get("action"):
            a = form_tag["action"]
            if a.startswith("http"):
                action = a
            elif a.startswith("/"):
                action = "https://account.sumai-surfin.com" + a

        # ── Step 2: POST でログイン（リダイレクトは手動制御） ──
        resp2 = _request_with_retry(session, "POST", action, data=form_data, allow_redirects=False)
        if resp2 is None:
            return False

        # POST 後のリダイレクトを手動で追跡（JS ベースログインの場合もリダイレクトが発生し得る）
        if resp2.status_code in (301, 302, 303, 307):
            redirect_url = resp2.headers.get("Location", "")
            if redirect_url:
                if redirect_url.startswith("/"):
                    redirect_url = "https://account.sumai-surfin.com" + redirect_url
                _request_with_retry(session, "GET", redirect_url, allow_redirects=True)

        # POST 成功判定: ssan Cookie が存在
        ssan_present = any(
            c.name == "ssan" and "account" in c.domain
            for c in session.cookies
        )

        if not ssan_present and resp2.status_code not in (200, 301, 302, 303, 307):
            print(f"住まいサーフィン: ログイン失敗（HTTP {resp2.status_code}、ssan Cookie なし）", file=sys.stderr)
            return False

        # ── Step 3: OAuth SSO フローで www 側セッションを確立 ──
        # www.sumai-surfin.com/member/ → account の /auth/authorize
        # → auth code → www の /member/auth/code.php → セッション Cookie 設定
        sso_resp = _request_with_retry(
            session, "GET", f"{BASE_URL}/member/", allow_redirects=True,
        )
        if sso_resp is None:
            print("住まいサーフィン: SSO フロー失敗（/member/ にアクセスできません）", file=sys.stderr)
            return False

        if "ログアウト" in sso_resp.text or "mypage" in sso_resp.url:
            print("住まいサーフィン: ログイン成功", file=sys.stderr)
            return True

        # フォールバック: 検索ページでログイン状態を確認
        check_resp = _request_with_retry(session, "GET", f"{BASE_URL}/search/", allow_redirects=True)
        if check_resp and "ログアウト" in check_resp.text:
            print("住まいサーフィン: ログイン成功（検索ページで確認）", file=sys.stderr)
            return True

        print("住まいサーフィン: ログイン失敗（SSO 後にログアウトリンクが見つかりません）", file=sys.stderr)
        print(f"  → ssan Cookie: {ssan_present}, total cookies: {len(session.cookies)}", file=sys.stderr)
        print(f"  → SSO URL: {sso_resp.url}", file=sys.stderr)
        return False

    except Exception as e:
        print(f"住まいサーフィン: ログインエラー: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return False


# ──────────────────────────── キャッシュ ────────────────────────────

def load_cache() -> dict:
    if CACHE_PATH.exists():
        try:
            return json.loads(CACHE_PATH.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as e:
            print(f"[SumaiSurfin] キャッシュ読み込み失敗（空キャッシュで続行）: {e}", file=sys.stderr)
    return {}


def save_cache(cache: dict) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    CACHE_PATH.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")


# ──────────────────────────── 検索 ────────────────────────────

def search_property(session: requests.Session, name: str, cache: dict) -> Optional[str]:
    """
    物件名で住まいサーフィンを検索し、/re/{id}/ の URL を返す。
    見つからなければ None。

    2026-02 更新: 検索 URL が /search/?q= から /search/result/?prefecture_id=13&keyword= に変更。
    """
    # キャッシュ確認
    clean_name = _normalize_name(name)
    if clean_name in cache:
        cached = cache[clean_name]
        if cached is None:
            return None  # 前回検索で見つからなかった
        return cached

    time.sleep(DELAY)

    try:
        params = {
            "prefecture_id": TOKYO_PREFECTURE_ID,
            "keyword": name,
        }
        resp = None
        for attempt in range(REQUEST_RETRIES):
            try:
                resp = session.get(SEARCH_RESULT_URL, params=params, timeout=30)
                if resp.status_code == 429:
                    wait = int(resp.headers.get("Retry-After", 60))
                    if attempt < REQUEST_RETRIES - 1:
                        time.sleep(wait)
                        continue
                if 500 <= resp.status_code < 600 and attempt < REQUEST_RETRIES - 1:
                    time.sleep(HTTP_BACKOFF_SEC * (attempt + 1))
                    continue
                resp.raise_for_status()
                break
            except requests.RequestException as e:
                if attempt < REQUEST_RETRIES - 1:
                    time.sleep(HTTP_BACKOFF_SEC * (attempt + 1))
                else:
                    raise
        if resp is None:
            return None

        soup = BeautifulSoup(resp.text, "lxml")

        # 検索結果からマンションページのリンクを探す
        best_url = None
        best_score = 0

        for a in soup.find_all("a", href=True):
            href = a["href"]
            if "/re/" not in href:
                continue

            # /re/12345/ 形式のみ
            m = re.search(r"/re/(\d+)/?", href)
            if not m:
                continue

            # リンクテキストやタイトルから物件名を取得
            link_text = a.get_text(strip=True)
            score = _name_similarity(clean_name, _normalize_name(link_text))
            if score > best_score:
                best_score = score
                re_id = m.group(1)
                best_url = f"{BASE_URL}/re/{re_id}/"

        # 閾値: 50% 以上の一致で採用
        if best_score >= 0.5 and best_url:
            cache[clean_name] = best_url

            # 検索結果カードからインラインデータを抽出（値上がり率等）
            inline = _extract_search_result_inline(soup, best_url)
            if inline:
                cache[clean_name + "__inline"] = inline

            return best_url

        # 見つからなかった
        cache[clean_name] = None
        return None

    except Exception as e:
        print(f"住まいサーフィン: 検索エラー ({name}): {e}", file=sys.stderr)
        return None


def _extract_search_result_inline(soup: BeautifulSoup, prop_url: str) -> dict:
    """検索結果カードから値上がり率・沖式中古時価をインライン抽出する。"""
    result: dict = {}
    page_text = soup.get_text()

    # 検索結果カードの値上がり率: "値上がり率 79.2%" or "値上がり率 XX.X%"
    # ただし "XX.X%" は非ログイン時のマスク値なので除外
    m = re.search(r"値上(?:が|り)り率\s*(\d+(?:\.\d+)?)\s*[%％]", page_text)
    if m:
        result["appreciation_rate"] = float(m.group(1))

    return result


def _normalize_name(s: str) -> str:
    """物件名を正規化（全角→半角、空白削除、末尾の部屋番号削除など）。"""
    import unicodedata
    s = unicodedata.normalize("NFKC", s)
    s = re.sub(r"\s+", "", s)
    # "○○マンション 5階" などの末尾階数を除去
    s = re.sub(r"\d+階.*$", "", s)
    return s.lower()


def _name_similarity(a: str, b: str) -> float:
    """簡易的な名前一致度（共通文字数ベース）。"""
    if not a or not b:
        return 0.0
    # a が b に含まれる、または b が a に含まれる
    if a in b or b in a:
        return 1.0
    # 共通文字の割合
    common = sum(1 for c in a if c in b)
    return common / max(len(a), len(b))


# ──────────────────────────── ページパース ────────────────────────────

def _fetch_property_page(
    session: requests.Session, url: str
) -> Optional[tuple[BeautifulSoup, str]]:
    """
    住まいサーフィンの物件ページ (/re/{id}/) を取得し、
    (BeautifulSoup, html_text) のタプルを返す。
    取得失敗時は None。
    """
    time.sleep(DELAY)

    try:
        resp = None
        for attempt in range(REQUEST_RETRIES):
            try:
                resp = session.get(url, timeout=30)
                if resp.status_code == 429:
                    wait = int(resp.headers.get("Retry-After", 60))
                    if attempt < REQUEST_RETRIES - 1:
                        time.sleep(wait)
                        continue
                resp.raise_for_status()
                break
            except (requests.RequestException, requests.exceptions.HTTPError) as e:
                if attempt < REQUEST_RETRIES - 1:
                    time.sleep(HTTP_BACKOFF_SEC * (attempt + 1))
                else:
                    raise
        if resp is None:
            return None
        html = resp.text
        soup = BeautifulSoup(html, "lxml")
        return soup, html
    except Exception as e:
        print(f"住まいサーフィン: ページ取得エラー ({url}): {e}", file=sys.stderr)
        return None


# ──────────────────────────── 中古専用パーサー ────────────────────────────

def parse_chuko_page(session: requests.Session, url: str) -> dict:
    """
    住まいサーフィンの中古マンションページをパースし、評価データの dict を返す。

    抽出フィールド:
      ss_sumai_surfin_url, ss_oki_price_70m2, ss_value_judgment,
      ss_station_rank, ss_ward_rank, ss_appreciation_rate,
      ss_favorite_count, ss_purchase_judgment,
      ss_sim_*, ss_loan_balance_*, ss_sim_base_price,
      ss_past_market_trends, ss_radar_data
    """
    result: dict = {"ss_sumai_surfin_url": url}

    fetched = _fetch_property_page(session, url)
    if fetched is None:
        return result
    soup, html = fetched

    # ── 沖式中古時価 (70m²換算) ──
    oki_price = _extract_oki_price_chuko(soup, html)
    if oki_price is not None:
        result["ss_oki_price_70m2"] = oki_price

    # ── 固定費判定（割安/適正/割高） ──
    value_judgment = _extract_value_judgment(soup, html)
    if value_judgment:
        result["ss_value_judgment"] = value_judgment

    # ── 駅ランキング ──
    station_rank = _extract_rank(soup, "駅", html)
    if station_rank:
        result["ss_station_rank"] = station_rank

    # ── 区ランキング ──
    ward_rank = _extract_rank(soup, "区", html)
    if ward_rank:
        result["ss_ward_rank"] = ward_rank

    # ── 中古値上がり率 (%) ──
    appreciation = _extract_appreciation_rate(soup, html)
    if appreciation is not None:
        result["ss_appreciation_rate"] = appreciation

    # ── お気に入り数 ──
    fav_count = _extract_favorite_count(soup, html)
    if fav_count is not None:
        result["ss_favorite_count"] = fav_count

    # ── 購入判定 ──
    purchase_judgment = _extract_purchase_judgment(soup, html)
    if purchase_judgment:
        result["ss_purchase_judgment"] = purchase_judgment

    # ── 値上がりシミュレーション ──
    sim_data = _extract_simulation_data(soup, html)
    result.update(sim_data)

    # ── シミュレーション基準価格（万円）──
    sim_base = _extract_sim_base_price(soup, html)
    if sim_base is not None:
        result["ss_sim_base_price"] = sim_base

    # ── 過去の相場推移テーブル ──
    past_trends = _extract_past_market_trends(soup, html)
    if past_trends:
        result["ss_past_market_trends"] = json.dumps(past_trends, ensure_ascii=False)

    # ── 周辺の中古マンション相場 ──
    surrounding = _extract_surrounding_properties(soup, html)
    if surrounding:
        result["ss_surrounding_properties"] = json.dumps(surrounding, ensure_ascii=False)

    # ── レーダーチャート用データ ──
    radar_data = _extract_radar_chart_data(soup, html)
    if radar_data:
        result["ss_radar_data"] = json.dumps(radar_data, ensure_ascii=False)

    # ── 最終バリデーション ──
    result = _validate_parsed_data(result, url)

    return result


# ──────────────────────────── 新築専用パーサー ────────────────────────────

def parse_shinchiku_page(session: requests.Session, url: str) -> dict:
    """
    住まいサーフィンの新築マンションページをパースし、評価データの dict を返す。

    抽出フィールド:
      ss_sumai_surfin_url, ss_profit_pct, ss_m2_discount,
      ss_value_judgment, ss_station_rank, ss_ward_rank,
      ss_favorite_count, ss_purchase_judgment,
      ss_sim_*, ss_loan_balance_*, ss_sim_base_price,
      ss_new_m2_price, ss_forecast_m2_price, ss_forecast_change_rate,
      ss_radar_data
    """
    result: dict = {"ss_sumai_surfin_url": url}

    fetched = _fetch_property_page(session, url)
    if fetched is None:
        return result
    soup, html = fetched

    # ── 沖式儲かる確率 ──
    profit_pct = _extract_profit_pct(soup, html)
    if profit_pct is not None:
        result["ss_profit_pct"] = profit_pct

    # ── m²割安額 ──
    m2_discount = _extract_m2_discount(soup, html)
    if m2_discount is not None:
        result["ss_m2_discount"] = m2_discount

    # ── 固定費判定（割安/適正/割高） ──
    value_judgment = _extract_value_judgment(soup, html)
    if value_judgment:
        result["ss_value_judgment"] = value_judgment

    # ── 駅ランキング ──
    station_rank = _extract_rank(soup, "駅", html)
    if station_rank:
        result["ss_station_rank"] = station_rank

    # ── 区ランキング ──
    ward_rank = _extract_rank(soup, "区", html)
    if ward_rank:
        result["ss_ward_rank"] = ward_rank

    # ── お気に入り数 ──
    fav_count = _extract_favorite_count(soup, html)
    if fav_count is not None:
        result["ss_favorite_count"] = fav_count

    # ── 購入判定 ──
    purchase_judgment = _extract_purchase_judgment(soup, html)
    if purchase_judgment:
        result["ss_purchase_judgment"] = purchase_judgment

    # ── 値上がりシミュレーション ──
    sim_data = _extract_simulation_data(soup, html)
    result.update(sim_data)

    # ── シミュレーション基準価格（万円）──
    sim_base = _extract_sim_base_price(soup, html)
    if sim_base is not None:
        result["ss_sim_base_price"] = sim_base

    # ── 10年後予測詳細（m²単価、予測変動率等） ──
    forecast = _extract_forecast_detail(soup, html)
    result.update(forecast)

    # ── 周辺の中古マンション相場 ──
    surrounding = _extract_surrounding_properties(soup, html)
    if surrounding:
        result["ss_surrounding_properties"] = json.dumps(surrounding, ensure_ascii=False)

    # ── レーダーチャート用データ ──
    radar_data = _extract_radar_chart_data(soup, html)
    if radar_data:
        result["ss_radar_data"] = json.dumps(radar_data, ensure_ascii=False)

    # ── 最終バリデーション ──
    result = _validate_parsed_data(result, url)

    return result


def _validate_parsed_data(result: dict, url: str) -> dict:
    """
    パース結果の最終バリデーション。
    regex の誤マッチによる異常値を除外する安全弁。
    """
    # バリデーションルール: (キー, 最小値, 最大値, 説明)
    validation_rules: list[tuple[str, float, float, str]] = [
        ("ss_profit_pct", 0, 100, "儲かる確率は0-100%"),
        ("ss_oki_price_70m2", 1500, 100000, "70㎡換算時価は1500万円以上"),
        ("ss_new_m2_price", 30, 2000, "㎡単価は30-2000万円"),
        ("ss_forecast_m2_price", 30, 2000, "予測㎡単価は30-2000万円"),
        ("ss_forecast_change_rate", -100, 300, "変動率は-100%～+300%"),
        ("ss_sim_best_5yr", 100, 100000, "シミュレーション値は100万円以上"),
        ("ss_sim_best_10yr", 100, 100000, "シミュレーション値は100万円以上"),
        ("ss_sim_standard_5yr", 100, 100000, "シミュレーション値は100万円以上"),
        ("ss_sim_standard_10yr", 100, 100000, "シミュレーション値は100万円以上"),
        ("ss_sim_worst_5yr", 100, 100000, "シミュレーション値は100万円以上"),
        ("ss_sim_worst_10yr", 100, 100000, "シミュレーション値は100万円以上"),
        ("ss_loan_balance_5yr", 100, 100000, "ローン残高は100万円以上"),
        ("ss_loan_balance_10yr", 100, 100000, "ローン残高は100万円以上"),
        ("ss_appreciation_rate", 0, 500, "値上がり率は0-500%"),
    ]
    for key, min_val, max_val, desc in validation_rules:
        val = result.get(key)
        if val is not None and isinstance(val, (int, float)):
            if val < min_val or val > max_val:
                print(
                    f"  [SumaiSurfin] バリデーション失敗 ({url}): "
                    f"{key}={val} — {desc} → 除外",
                    file=sys.stderr,
                )
                del result[key]

    # 購入判定が単なるラベル名の場合は除外
    pj = result.get("ss_purchase_judgment")
    if pj in ("購入判定", "値上がり判定", "--"):
        del result["ss_purchase_judgment"]

    # シミュレーションデータの整合性チェック:
    # 全ケースが同じ値の場合は誤取得の可能性が高い
    sim_keys_5yr = ["ss_sim_best_5yr", "ss_sim_standard_5yr", "ss_sim_worst_5yr"]
    sim_keys_10yr = ["ss_sim_best_10yr", "ss_sim_standard_10yr", "ss_sim_worst_10yr"]
    for sim_keys in [sim_keys_5yr, sim_keys_10yr]:
        vals = [result.get(k) for k in sim_keys if result.get(k) is not None]
        if len(vals) == 3 and len(set(vals)) == 1:
            # ベスト/標準/ワーストが全て同じ値 → 異常データ
            print(
                f"  [SumaiSurfin] シミュレーション整合性エラー ({url}): "
                f"全ケース同値={vals[0]} → 除外",
                file=sys.stderr,
            )
            for k in sim_keys:
                result.pop(k, None)

    return result


def _extract_profit_pct(soup: BeautifulSoup, html: str) -> Optional[int]:
    """沖式儲かる確率（%）を抽出。"""
    # パターン1: "儲かる確率" の近傍（200文字以内）から数値を探す
    # re.DOTALL + .*? で HTML 全体をスキャンすると、ユーザーレビュー等の
    # 無関係な数値を拾ってしまうため、検索範囲を制限する。
    m = re.search(r"儲かる確率", html)
    if m:
        # "儲かる確率" の後ろ 200 文字以内で数値 + % を探す
        search_area = html[m.start():m.start() + 200]
        num = re.search(r"儲かる確率.*?(\d{1,3})\s*[%％]", search_area, re.DOTALL)
        if num:
            val = int(num.group(1))
            # 儲かる確率は 0-100% の範囲
            if 0 <= val <= 100:
                return val

    # パターン2: DOM から探す（親要素の範囲に限定）
    for el in soup.find_all(string=re.compile(r"儲かる確率")):
        parent = el.find_parent()
        if parent:
            # 近傍の数値を探す
            container = parent.find_parent()
            if container:
                num = re.search(r"(\d{1,3})\s*[%％]", container.get_text())
                if num:
                    val = int(num.group(1))
                    if 0 <= val <= 100:
                        return val
    return None


def _extract_oki_price_chuko(soup: BeautifulSoup, html: str) -> Optional[int]:
    """沖式中古時価（70m²換算, 万円）を抽出。中古専用。

    注意: "沖式中古時価m²単価" (㎡あたりの単価) を誤取得しないよう、
    70m² 換算パターンを優先し、m²単価パターンを除外する。
    """
    patterns = [
        # 優先: "沖式中古時価(70m2換算) X,XXX万円" — 最も確実
        r"沖式中古時価\s*[\(（]70.{0,10}?[\)）]\s*.{0,50}?(\d[\d,]+)\s*万円",
        # 汎用: m²単価パターンを除外して検索
        r"沖式中古時価(?![㎡m²]\s*単価).{0,200}?(\d[\d,]+)\s*万円",
    ]
    for pat in patterns:
        m = re.search(pat, html, re.DOTALL)
        if m:
            val = int(m.group(1).replace(",", ""))
            # 70m² 換算の時価は最低でも 1500 万円以上（㎡単価等の誤取得を防止）
            if val >= 1500:
                return val
    return None


def _extract_m2_discount(soup: BeautifulSoup, html: str) -> Optional[int]:
    """m²割安額（万円/m²）を抽出。新築専用。

    住まいサーフィンの新築ページに表示される「m²割安額」を取得する。
    負値 = 割安、正値 = 割高。
    """
    patterns = [
        # "m²割安額 -12万円" / "㎡割安額 +5万円"
        r"[m㎡²]\s*[²2]?\s*割安額.{0,100}?([+-]?\d[\d,]*)\s*万円",
        # "割安額 -12万円/m²"
        r"割安額.{0,100}?([+-]?\d[\d,]*)\s*万円\s*/?\s*[m㎡²]",
    ]
    for pat in patterns:
        m = re.search(pat, html, re.DOTALL)
        if m:
            return int(m.group(1).replace(",", ""))
    return None


def _extract_sim_base_price(soup: BeautifulSoup, html: str) -> Optional[int]:
    """シミュレーションフォームの基準価格（万円）を抽出する。

    住まいサーフィンの「購入条件を入力」フォームのデフォルト価格を取得。
    この値は値上がりシミュレーションの計算基準となる。
    """
    # パターン1: 「購入条件」フッター内の価格
    # "購入条件 価格: 6,000万円 / 金利: 0.79%..."
    m = re.search(r"購入条件.{0,50}?価格[：:]\s*([\d,]+)\s*万", html, re.DOTALL)
    if m:
        val = int(m.group(1).replace(",", ""))
        if 1000 <= val <= 50000:
            return val

    # パターン2: input フォームの value 属性（希望住戸の価格フィールド）
    for inp in soup.find_all("input"):
        name = inp.get("name", "").lower()
        if "price" in name or "kakaku" in name:
            val_str = inp.get("value", "")
            if val_str and val_str.isdigit():
                val = int(val_str)
                if 1000 <= val <= 50000:
                    return val

    # パターン3: JavaScript 変数から抽出
    m = re.search(r"(?:price|kakaku|希望.*?価格)\s*[=:]\s*(\d{4,5})", html)
    if m:
        val = int(m.group(1))
        if 1000 <= val <= 50000:
            return val

    return None


def _extract_value_judgment(soup: BeautifulSoup, html: str) -> Optional[str]:
    """
    固定費判定（割安/適正/割高）を抽出する。
    HTML 上の「【沖式】固定費判定★-円★割安」等のパターンから取得。
    ※ 販売価格の割安判定はエビデンス提出が必要で自動取得不可。
    """
    # ── パターン1: 「固定費判定」セクションの判定結果 ──
    # HTML 例: 固定費判定★-円★割安  or  固定費判定 16,900円 割安
    m = re.search(
        r"固定費判定.{0,60}?(やや割安|やや割高|割安|割高|適正)",
        html, re.DOTALL,
    )
    if m:
        return m.group(1)

    # ── パターン2: 「沖式」を含む判定結果（ページ上半分のみ検索） ──
    half = html[:len(html) // 2]
    for keyword in ("やや割安", "やや割高", "割安", "割高", "適正"):
        if re.search(rf"沖式.*?判定.{{0,80}}?{keyword}", half, re.DOTALL):
            return keyword

    return None


def _extract_rank(soup: BeautifulSoup, keyword: str, html: str) -> Optional[str]:
    """
    駅ランキング or 区ランキングを "N/M" 形式で抽出。
    keyword: "駅" or "区"
    """
    # パターン: "赤羽橋駅 全1件中 1 位" or "東京都港区 全26件中 20 位"
    if keyword == "駅":
        pattern = r"(\S+駅)\s*全(\d+)件中\s*(\d+)\s*位"
    else:
        pattern = r"(東京都\S+区)\s*全(\d+)件中\s*(\d+)\s*位"

    m = re.search(pattern, html)
    if m:
        total = m.group(2)
        rank = m.group(3)
        return f"{rank}/{total}"

    return None


def _extract_appreciation_rate(soup: BeautifulSoup, html: str) -> Optional[float]:
    """
    中古値上がり率 (%) を抽出。
    「沖式資産性評価」セクションから当該物件固有の値を取得する。
    （周辺マンション比較テーブルの値を誤マッチしないよう注意）
    """
    # ── 戦略 1: 「沖式資産性評価」セクション内の値上がり率 ──
    # 売却タブの「沖式資産性評価」見出し以降にある「中古値上がり率 XX%」
    oki_pos = html.find("沖式資産性評価")
    if oki_pos >= 0:
        # セクション開始から 500 文字以内を検索（他セクションに入らないよう制限）
        search_area = html[oki_pos:oki_pos + 500]
        m = re.search(r"中古値上がり率.*?(\d+(?:\.\d+)?)\s*[%％]", search_area, re.DOTALL)
        if m:
            return float(m.group(1))

    # ── 戦略 2: 「過去の相場推移」セクション周辺 ──
    # 過去の相場推移見出しの直前にある値上がり率
    trend_pos = html.find("過去の相場推移")
    if trend_pos > 200:
        # 見出しの 300 文字前から見出しまでの区間を検索
        search_area = html[max(0, trend_pos - 300):trend_pos]
        m = re.search(r"値上がり率.*?(\d+(?:\.\d+)?)\s*[%％]", search_area, re.DOTALL)
        if m:
            return float(m.group(1))

    # ── 戦略 3: 周辺マンションテーブルの前にある値上がり率 ──
    # 「周辺の中古マンション相場」セクションより前の部分だけを検索
    surround_pos = html.find("周辺の中古マンション相場")
    search_area = html[:surround_pos] if surround_pos > 0 else html[:5000]
    m = re.search(r"中古値上がり率.*?(\d+(?:\.\d+)?)\s*[%％]", search_area, re.DOTALL)
    if m:
        return float(m.group(1))

    return None


def _extract_favorite_count(soup: BeautifulSoup, html: str) -> Optional[int]:
    """お気に入り数を抽出。"""
    # パターン1: "お気に入り" のランキング偏差値テキストからスコアを取得
    # 住まいサーフィンでは「お気に入りランキング XX.X点」のように表示される
    m = re.search(r"お気に入りランキング.*?(\d+(?:\.\d+)?)\s*点", html, re.DOTALL)
    if m:
        # スコアを整数として返す（偏差値的な値）
        return int(float(m.group(1)))

    # パターン2: "お気に入り数" or "お気に入り件数" 付近の数値
    m = re.search(r"お気に入り(?:数|件数).*?(\d+)", html, re.DOTALL)
    if m:
        return int(m.group(1))

    # パターン3: "お気に入り" セクション内のスコア（ランキングの得点部分）
    for el in soup.find_all(string=re.compile(r"お気に入り")):
        parent = el.find_parent()
        if parent:
            container = parent.find_parent()
            if container:
                # "XX.X点" パターン
                num = re.search(r"(\d+(?:\.\d+)?)\s*点", container.get_text())
                if num:
                    return int(float(num.group(1)))
    return None


def _extract_purchase_judgment(soup: BeautifulSoup, html: str) -> Optional[str]:
    """購入判定 / 値上がり判定のテキストを抽出。

    住まいサーフィンの判定は以下の 3 パターン:
      - "値上がりが期待できます"
      - "条件付きで値上がりが期待できます"
      - "永住することで資産化が期待できます"
    """
    # ── パターン1: 既知の判定文言を直接検索 ──
    known_judgments = [
        "条件付きで値上がりが期待できます",
        "値上がりが期待できます",
        "永住することで資産化が期待できます",
    ]
    for judgment in known_judgments:
        if judgment in html:
            return judgment

    # ── パターン2: "値上がり判定" の近傍から判定テキストを探す ──
    m = re.search(r"値上がり判定", html)
    if m:
        # 判定の後ろ 300 文字以内を検索
        search_area = html[m.start():m.start() + 300]
        # "値上がり" or "永住" を含む文を探す
        judge_m = re.search(
            r"((?:条件付きで)?値上がり[^\s<]{1,30}|永住[^\s<]{1,30})",
            search_area,
        )
        if judge_m:
            text = judge_m.group(1).strip()
            # "値上がり判定" 自体を再キャプチャしないようフィルタ
            if text != "値上がり判定":
                return text

    # ── パターン3: DOM から探す ──
    for el in soup.find_all(string=re.compile(r"値上がり判定|購入判定")):
        parent = el.find_parent()
        if parent:
            sibling = parent.find_next_sibling()
            if sibling:
                text = sibling.get_text(strip=True)
                if text and text not in ("購入判定", "値上がり判定", "--"):
                    return text
    return None


def _extract_forecast_detail(soup: BeautifulSoup, html: str) -> dict:
    """
    10年後予測詳細データを抽出する（新築のみ）。
    返却例:
      {
        "ss_new_m2_price": 264,        # 新築時m²単価（万円）
        "ss_forecast_m2_price": 295,   # 10年後予測m²単価（万円）
        "ss_forecast_change_rate": 11.7,  # 予測変動率（%）
      }

    注意: 各 regex は検索範囲を 200 文字以内に制限する。
    re.DOTALL + .*? でページ全体を検索すると、ユーザーレビュー内の
    「平均㎡単価144万円」等の無関係な数値を誤取得する。
    """
    result: dict = {}

    # ── 新築時m²単価 ──
    # パターン: "新築時価格表㎡単価" or "新築時m²単価" → "264 万円" or "264万/㎡"
    m = re.search(r"新築時(?:価格表)?[㎡m²]単価.{0,200}?(\d+)\s*万", html, re.DOTALL)
    if m:
        val = int(m.group(1))
        # ㎡単価は東京で概ね 50～1000 万円/㎡ の範囲
        if 30 <= val <= 2000:
            result["ss_new_m2_price"] = val

    # ── 沖式新築時価㎡単価 ──
    m = re.search(r"沖式新築時価[㎡m²]単価.{0,200}?(\d+)\s*万", html, re.DOTALL)
    if m:
        # ss_new_m2_price が未取得の場合のフォールバック
        if "ss_new_m2_price" not in result:
            val = int(m.group(1))
            if 30 <= val <= 2000:
                result["ss_new_m2_price"] = val

    # ── 10年後予測m²単価 ──
    m = re.search(r"10年後予測[㎡m²].{0,200}?(\d+)\s*万", html, re.DOTALL)
    if m:
        val = int(m.group(1))
        if 30 <= val <= 2000:
            result["ss_forecast_m2_price"] = val

    # ── 予測変動率 ──
    m = re.search(r"予測変動率.{0,100}?([+-]?\d+(?:\.\d+)?)\s*[%％]", html, re.DOTALL)
    if m:
        val = float(m.group(1))
        # 変動率は通常 -50% ～ +200% 程度
        if -100 <= val <= 300:
            result["ss_forecast_change_rate"] = val

    # フォールバック: 新築時m²単価と沖式新築時価㎡単価から変動率を計算
    if "ss_forecast_change_rate" not in result:
        new_p = result.get("ss_new_m2_price")
        fc_p = result.get("ss_forecast_m2_price")
        if new_p and fc_p and new_p > 0:
            result["ss_forecast_change_rate"] = round((fc_p - new_p) / new_p * 100, 1)

    return result


def _extract_surrounding_properties(soup: BeautifulSoup, html: str) -> Optional[list]:
    """
    周辺の中古マンション相場テーブルからデータを抽出する。
    返却形式:
      [
        {"name": "サンクタス大森ヴァッサーハウス", "appreciation_rate": 79.2, "oki_price_70m2": 7700},
        {"name": "スターロワイヤル南大井", "oki_price_70m2": 7630},
        ...
      ]
    注意: 中古値上がり率はログイン時のみ表示（非ログイン時は "XX%" で表示されるため取得不可）
    """
    results: list = []

    # 「周辺の中古マンション相場」セクションのテーブルを探す
    for heading in soup.find_all(string=re.compile(r"周辺の中古マンション相場")):
        parent = heading.find_parent()
        if not parent:
            continue

        # 見出し以降の最も近い <table> を探す
        table = parent.find_next("table")
        if not table:
            # 親の兄弟要素にテーブルがあるか確認
            for sibling in parent.find_all_next():
                if sibling.name == "table":
                    table = sibling
                    break
                # 別のセクション見出しに到達したら中止
                if sibling.get_text(strip=True) in ("過去の相場推移", "沖式住戸比較レポート"):
                    break
        if not table:
            continue

        rows = table.find_all("tr")
        for row in rows:
            cells = row.find_all(["td", "th"])
            if len(cells) < 2:
                continue

            # ヘッダー行をスキップ（"物件名" を含む行）
            first_cell_text = cells[0].get_text(strip=True)
            if "物件名" in first_cell_text:
                continue

            entry: dict = {}

            # 物件名: 最初のセルのリンクテキストまたはテキスト
            link = cells[0].find("a")
            name = link.get_text(strip=True) if link else first_cell_text
            if name and len(name) > 1 and name != "物件名":
                entry["name"] = name
                # リンクURLも取得（任意）
                if link and link.get("href"):
                    href = link["href"]
                    if href.startswith("/"):
                        entry["url"] = f"{BASE_URL}{href}"
                    elif href.startswith("http"):
                        entry["url"] = href

            # 中古値上がり率: 2番目のセル
            if len(cells) >= 2:
                rate_text = cells[1].get_text(strip=True)
                # "XX%" はマスク値なので除外
                if "XX" not in rate_text:
                    rate_m = re.search(r"(\d+(?:\.\d+)?)\s*[%％]", rate_text)
                    if rate_m:
                        entry["appreciation_rate"] = float(rate_m.group(1))

            # 沖式中古時価（70m²換算）: 3番目のセル
            if len(cells) >= 3:
                price_text = cells[2].get_text(strip=True)
                price_m = re.search(r"([\d,]+)\s*万円", price_text)
                if price_m:
                    val = int(price_m.group(1).replace(",", ""))
                    if val >= 500:  # 最低 500 万円以上
                        entry["oki_price_70m2"] = val

            # 物件名がありかつ価格があれば追加
            if "name" in entry and "oki_price_70m2" in entry:
                results.append(entry)

        # 最初のテーブルだけ処理
        if results:
            break

    return results if results else None


def _extract_past_market_trends(soup: BeautifulSoup, html: str) -> Optional[list]:
    """
    過去の相場推移テーブルからデータを抽出する。
    返却形式:
      [
        {"period": "2015年以前", "price_man": 11934, "area_m2": 70.2, "unit_price_man": 170},
        {"period": "2016～2017年", "price_man": 11162, ...},
        ...
      ]
    """
    results: list = []

    # 「過去の相場推移」セクションのテーブルを探す
    # ページ内に 2 つ存在する場合があるので最初の 1 つを使用
    for heading in soup.find_all(string=re.compile(r"過去の相場推移")):
        parent = heading.find_parent()
        if not parent:
            continue

        # 見出し以降の最も近い <table> を探す
        table = parent.find_next("table")
        if not table:
            continue

        rows = table.find_all("tr")
        for row in rows:
            cells = row.find_all(["td", "th"])
            if len(cells) < 2:
                continue

            period = cells[0].get_text(strip=True)
            price_text = cells[1].get_text(strip=True)

            # 年代パターン: "2015年以前", "2016～2017年", "2022年～"
            if not re.search(r"\d{4}年", period):
                continue

            entry: dict = {"period": period}

            # 価格: "11,934万円/70.2㎡（㎡単価：170万）"
            price_m = re.search(r"([\d,]+)万円", price_text)
            if price_m:
                entry["price_man"] = int(price_m.group(1).replace(",", ""))

            # 面積: "70.2㎡"
            area_m = re.search(r"(\d+(?:\.\d+)?)(?:㎡|m)", price_text)
            if area_m:
                entry["area_m2"] = float(area_m.group(1))

            # ㎡単価: "㎡単価：170万"
            unit_m = re.search(r"㎡単価[：:]?\s*(\d+)万", price_text)
            if unit_m:
                entry["unit_price_man"] = int(unit_m.group(1))

            if "price_man" in entry:
                results.append(entry)

        # 最初のテーブルだけ処理
        if results:
            break

    return results if results else None


def _extract_simulation_data(soup: BeautifulSoup, html: str) -> dict:
    """
    値上がりシミュレーションテーブル + ローン残高のデータを抽出。
    返却例: {
        "ss_sim_best_5yr": 7344,
        "ss_sim_best_10yr": 7788,
        "ss_sim_standard_5yr": 6744,
        "ss_sim_standard_10yr": 6588,
        "ss_sim_worst_5yr": 6144,
        "ss_sim_worst_10yr": 5388,
        "ss_loan_balance_5yr": 5395,
        "ss_loan_balance_10yr": 4757,
    }
    """
    result: dict = {}

    # 値上がりシミュレーションのテーブルを探す
    # テーブルは「ベストケース」「標準ケース」「ワーストケース」の行を持つ
    tables = soup.find_all("table")

    for table in tables:
        text = table.get_text()
        if "ベストケース" not in text and "標準ケース" not in text:
            continue

        rows = table.find_all("tr")
        for row in rows:
            cells = row.find_all(["td", "th"])
            if len(cells) < 3:
                continue

            row_text = cells[0].get_text(strip=True)

            # ケース判定
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

            # 5年後 (cells[1]) と 10年後 (cells[2]) の値を抽出
            for idx, suffix in [(1, "5yr"), (2, "10yr")]:
                if idx < len(cells):
                    val_text = cells[idx].get_text(strip=True)
                    num = re.search(r"([\d,]+)\s*万", val_text)
                    if num:
                        val = int(num.group(1).replace(",", ""))
                        if case_key == "__loan__":
                            result[f"ss_loan_balance_{suffix}"] = val
                        else:
                            result[f"ss_sim_{case_key}_{suffix}"] = val

    # テーブルが見つからなかった場合、正規表現でフォールバック
    # 検索範囲を 500 文字以内に制限し、値のバリデーションを実施
    if not result:
        case_patterns = {
            "best": r"ベストケース",
            "standard": r"標準ケース",
            "worst": r"ワーストケース",
        }
        for case_key, case_pat in case_patterns.items():
            # "ベストケース ... 7,344万円 ... 7,788万円" のようなパターン
            m = re.search(
                case_pat + r".{0,500}?([\d,]+)\s*万円.{0,200}?([\d,]+)\s*万円",
                html, re.DOTALL,
            )
            if m:
                val_5yr = int(m.group(1).replace(",", ""))
                val_10yr = int(m.group(2).replace(",", ""))
                # シミュレーション値は通常 500～50000 万円の範囲
                if val_5yr >= 500 and val_10yr >= 500:
                    result[f"ss_sim_{case_key}_5yr"] = val_5yr
                    result[f"ss_sim_{case_key}_10yr"] = val_10yr

    # テーブル解析結果もバリデーション: 極端に小さい値は除外
    validated: dict = {}
    for k, v in result.items():
        if isinstance(v, int) and v < 100:
            # 100万円未満のシミュレーション値は不正データとして除外
            print(f"  [SumaiSurfin] シミュレーション値バリデーション失敗: {k}={v} (100万円未満のため除外)", file=sys.stderr)
            continue
        validated[k] = v

    return validated


# ──────────────────────────── レーダーチャート ────────────────────────────

# 住まいサーフィンのラベル → iOS RadarData の named-key マッピング
# サイト準拠の 6 軸: 沖式中古時価m²単価, 築年数, お気に入り数, 徒歩分数, 中古値上がり率, 総戸数
RADAR_LABEL_TO_KEY: dict[str, str] = {
    "沖式中古時価m²単価": "oki_price_m2",
    "沖式中古時価m\u00b2単価": "oki_price_m2",
    "沖式時価m²単価": "oki_price_m2",
    "沖式時価": "oki_price_m2",
    "中古沖式時価m²単価": "oki_price_m2",
    "築年数": "build_age",
    "お気に入り数": "favorites",
    "お気に入り": "favorites",
    "徒歩分数": "walk_min",
    "徒歩分": "walk_min",
    "中古値上がり率": "appreciation_rate",
    "値上がり率": "appreciation_rate",
    "値上り率": "appreciation_rate",
    "総戸数": "total_units",
}


def _extract_radar_chart_data(soup: BeautifulSoup, html: str) -> Optional[dict]:
    """
    住まいサーフィンのレーダーチャートデータを抽出する。

    戦略:
      1) <script> タグ内の Chart.js / Highcharts の radar 設定を探す
      2) 見つからなければ、ページ上のランキング偏差値スコアを構築する

    返却形式 (成功時): iOS 互換の named-key 形式（サイト準拠の 6 軸）
      {
        "oki_price_m2":      38.4,   # 沖式中古時価m²単価
        "build_age":         47.1,   # 築年数
        "favorites":         40.7,   # お気に入り数
        "walk_min":          52.3,   # 徒歩分数
        "appreciation_rate": 55.8,   # 中古値上がり率
        "total_units":       48.0,   # 総戸数
      }
    偏差値 50 = 行政区平均
    """

    # ── 戦略 1: <script> タグ内の Chart.js radar config を探す ──
    radar = _try_extract_chartjs_radar(soup, html)
    if radar:
        return radar

    # ── 戦略 2: ランキング偏差値スコアをパースして構築 ──
    return _build_radar_from_rankings(soup, html)


def _try_extract_chartjs_radar(soup: BeautifulSoup, html: str) -> Optional[dict]:
    """
    <script> タグから Chart.js の type:'radar' 設定を探し、
    labels / datasets を抽出して iOS named-key 形式で返す。
    """
    for script in soup.find_all("script"):
        src = script.string
        if not src:
            continue

        # Chart.js radar 判定
        if "radar" not in src:
            continue

        # type: 'radar' or type: "radar"
        if not re.search(r"""type\s*:\s*['"]radar['"]""", src):
            continue

        # labels 抽出: labels: ['a', 'b', ...]
        labels_m = re.search(
            r"labels\s*:\s*\[(.*?)\]", src, re.DOTALL
        )
        if not labels_m:
            continue

        raw_labels = labels_m.group(1)
        labels = re.findall(r"""['"]([^'"]+)['"]""", raw_labels)
        if len(labels) < 3:
            continue

        # datasets 抽出: datasets: [{...data:[...]...}, {....}]
        datasets_m = re.search(
            r"datasets\s*:\s*\[(.*)\]", src, re.DOTALL
        )
        if not datasets_m:
            continue

        # 各 dataset の data 配列を取得
        data_arrays = re.findall(
            r"data\s*:\s*\[([\d.,\s-]+)\]",
            datasets_m.group(1),
        )

        if len(data_arrays) < 1:
            continue

        # 1 番目 = 本物件
        property_values = [float(v.strip()) for v in data_arrays[0].split(",") if v.strip()]

        if len(property_values) != len(labels):
            continue

        # labels → iOS named-key に変換
        result: dict[str, float] = {}
        for lbl, val in zip(labels, property_values):
            key = RADAR_LABEL_TO_KEY.get(lbl)
            if key:
                result[key] = val

        if len(result) >= 2:
            return result

    return None


def _build_radar_from_rankings(soup: BeautifulSoup, html: str) -> Optional[dict]:
    """
    ページ上のランキングセクションから偏差値スコアを抽出し、
    iOS named-key 形式のレーダーチャートデータを構築する。
    サイト準拠の 6 軸: 沖式中古時価m²単価, 築年数, お気に入り数, 徒歩分数, 中古値上がり率, 総戸数
    """
    ranking_defs = [
        ("oki_price_m2", r"(?:沖式中古時価|沖式時価)[m㎡²]*単価.*?ランキング.*?(\d+(?:\.\d+)?)\s*点"),
        ("build_age", r"築年数.*?ランキング.*?(\d+(?:\.\d+)?)\s*点"),
        ("favorites", r"お気に入り(?:数)?ランキング.*?(\d+(?:\.\d+)?)\s*点"),
        ("walk_min", r"徒歩分(?:数)?.*?ランキング.*?(\d+(?:\.\d+)?)\s*点"),
        ("appreciation_rate", r"(?:中古)?値上(?:が|り)り率.*?ランキング.*?(\d+(?:\.\d+)?)\s*点"),
        ("total_units", r"総戸数.*?ランキング.*?(\d+(?:\.\d+)?)\s*点"),
    ]

    result: dict[str, float] = {}

    for key, pattern in ranking_defs:
        m = re.search(pattern, html, re.DOTALL)
        if m:
            result[key] = float(m.group(1))

    if len(result) < 2:
        return None

    return result


def _finalize_radar_data(listing: dict, property_type: str = "chuko") -> None:
    """
    listing の ss_radar_data を iOS 互換の named-key 形式に正規化し、
    不足軸を ss_* フィールドや walk_min から補完する。

    iOS RadarData の 6 軸（偏差値 20-80, 50=平均 — サイト準拠）:
      oki_price_m2      沖式中古時価m²単価
      build_age         築年数
      favorites         お気に入り数
      walk_min          徒歩分数
      appreciation_rate 中古値上がり率
      total_units       総戸数
    """
    ios_data: dict[str, float] = {}

    # 1) 既存 ss_radar_data をパース（旧 labels/values 形式 or named-key 形式）
    raw = listing.get("ss_radar_data")
    if raw:
        try:
            parsed = json.loads(raw) if isinstance(raw, str) else raw
        except (json.JSONDecodeError, TypeError):
            parsed = None

        if isinstance(parsed, dict):
            if "labels" in parsed and "values" in parsed:
                # 旧形式: {"labels": [...], "values": [...]} → named-key に変換
                for lbl, val in zip(parsed["labels"], parsed["values"]):
                    key = RADAR_LABEL_TO_KEY.get(lbl)
                    if key and isinstance(val, (int, float)):
                        ios_data[key] = float(val)
            else:
                # 既に named-key 形式（新旧キー両方に対応）
                for k in ("oki_price_m2", "build_age", "favorites",
                          "walk_min", "appreciation_rate", "total_units"):
                    if k in parsed and isinstance(parsed[k], (int, float)):
                        ios_data[k] = float(parsed[k])
                # 旧キーの互換変換
                if "asset_value" in parsed and "appreciation_rate" not in ios_data:
                    ios_data["appreciation_rate"] = float(parsed["asset_value"])
                if "access_count" in parsed and "oki_price_m2" not in ios_data:
                    ios_data["oki_price_m2"] = float(parsed["access_count"])

    # 2) ss_* フィールドから不足軸を補完（中古のみ — 中古固有のフィールドで推定）
    if property_type == "chuko":
        if "oki_price_m2" not in ios_data:
            oki = listing.get("ss_oki_price_70m2")
            if oki is not None:
                ios_data["oki_price_m2"] = 55.0

        if "appreciation_rate" not in ios_data:
            rate = listing.get("ss_appreciation_rate")
            if rate is not None:
                ios_data["appreciation_rate"] = min(80.0, max(20.0, 50.0 + float(rate)))

    # 共通: お気に入り・徒歩分数の補完
    if "favorites" not in ios_data:
        fav = listing.get("ss_favorite_count")
        if fav is not None:
            ios_data["favorites"] = min(80.0, max(20.0, 50.0 + float(fav) / 5.0))

    if "walk_min" not in ios_data:
        walk = listing.get("walk_min")
        if walk is not None:
            try:
                w = int(walk)
                ios_data["walk_min"] = min(80.0, max(20.0, 65.0 - (w - 5) * 3.0))
            except (ValueError, TypeError):
                pass

    # build_age, total_units はフォールバック不可（サイトからの偏差値のみ）

    # 3) 2 軸以上あれば iOS 互換 JSON としてセット
    if len(ios_data) >= 2:
        listing["ss_radar_data"] = json.dumps(ios_data, ensure_ascii=False)
    # 元々のデータが旧形式だった場合でも、上で変換済み


# ──────────────────────────── メイン処理 ────────────────────────────

def enrich_listings(input_path: str, output_path: str, session: requests.Session,
                    property_type: str = "chuko") -> None:
    """
    JSON ファイルの各物件に住まいサーフィンの評価データを付加する。
    property_type: "chuko" (中古) or "shinchiku" (新築)
    """
    output_path = Path(output_path)

    with open(input_path, "r", encoding="utf-8") as f:
        listings = json.load(f)

    if not isinstance(listings, list):
        print("住まいサーフィン: 入力が配列ではありません", file=sys.stderr)
        return

    cache = load_cache()
    enriched_count = 0
    skip_count = 0
    not_found_count = 0
    no_data_count = 0
    target_count = 0

    for i, listing in enumerate(listings):
        name = listing.get("name", "")
        if not name:
            continue

        # 既に enrichment 済みならスキップ
        # 新築は ss_profit_pct / ss_m2_discount、中古は ss_oki_price_70m2 / ss_appreciation_rate で判定
        if property_type == "shinchiku":
            already = (listing.get("ss_profit_pct") is not None
                       or listing.get("ss_m2_discount") is not None
                       or listing.get("ss_purchase_judgment") is not None)
        else:
            already = listing.get("ss_oki_price_70m2") is not None or listing.get("ss_appreciation_rate") is not None
        if already:
            skip_count += 1
            continue

        target_count += 1

        # 検索
        prop_url = search_property(session, name, cache)
        if not prop_url:
            not_found_count += 1
            continue

        # 検索結果ページのインラインデータを取得（値上がり率等のフォールバック用）
        clean_name = _normalize_name(name)
        inline_data = cache.get(clean_name + "__inline", {})

        # ページパース（中古・新築で専用パーサーを使い分け）
        if property_type == "chuko":
            data = parse_chuko_page(session, prop_url)
        else:
            data = parse_shinchiku_page(session, prop_url)

        # 検索結果のインラインデータで補完（detail ページで取得できなかった場合）
        if "ss_appreciation_rate" not in data and inline_data.get("appreciation_rate"):
            data["ss_appreciation_rate"] = inline_data["appreciation_rate"]

        # データをマージ
        for k, v in data.items():
            listing[k] = v

        if any(k.startswith("ss_") and k != "ss_sumai_surfin_url" for k in data):
            enriched_count += 1
            parts = []
            if data.get("ss_profit_pct") is not None:
                parts.append(f"儲かる確率: {data['ss_profit_pct']}%")
            if data.get("ss_appreciation_rate") is not None:
                parts.append(f"値上がり率: {data['ss_appreciation_rate']}%")
            if data.get("ss_value_judgment"):
                parts.append(f"判定: {data['ss_value_judgment']}")
            if data.get("ss_past_market_trends"):
                parts.append("相場推移✓")
            if data.get("ss_favorite_count") is not None:
                parts.append(f"お気に入り: {data['ss_favorite_count']}点")
            if data.get("ss_surrounding_properties"):
                parts.append("周辺相場✓")
            if data.get("ss_radar_data"):
                parts.append("レーダー✓")
            if data.get("ss_sim_best_5yr") is not None:
                parts.append("シミュレーション✓")
            if data.get("ss_loan_balance_5yr") is not None:
                parts.append("ローン残高✓")
            if data.get("ss_forecast_change_rate") is not None:
                parts.append(f"変動率: {data['ss_forecast_change_rate']:+.1f}%")
            print(f"  ✓ {name} — {', '.join(parts) or 'URL取得'}", file=sys.stderr)
        else:
            no_data_count += 1

        # 進捗: 20件ごとにサマリー
        processed = enriched_count + not_found_count + no_data_count
        if processed > 0 and processed % 20 == 0:
            print(f"  住まいサーフィン進捗: {processed}/{target_count}件処理済 (成功: {enriched_count})", file=sys.stderr)

    # キャッシュ保存
    save_cache(cache)

    # 全物件のレーダーデータを iOS 互換形式に正規化・不足軸を補完
    radar_count = 0
    for listing in listings:
        had_radar = listing.get("ss_radar_data") is not None
        _finalize_radar_data(listing, property_type=property_type)
        if not had_radar and listing.get("ss_radar_data") is not None:
            radar_count += 1
    if radar_count:
        print(f"レーダーデータ補完: {radar_count}件（既存 ss_*/walk_min から生成）", file=sys.stderr)

    # 出力（原子的書き込み）
    tmp_path = output_path.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp_path.replace(output_path)

    print(f"住まいサーフィン enrichment 完了: {enriched_count}件成功, {not_found_count}件未発見, {no_data_count}件データなし, {skip_count}件スキップ(済)", file=sys.stderr)


def finalize_radar_only(input_path: str, output_path: str,
                        property_type: str = "chuko") -> None:
    """
    Web スクレイピングなしで、既存 ss_* / walk_min からレーダーデータを補完する。
    SUMAI_USER / SUMAI_PASS が不要。
    """
    output_path_p = Path(output_path)

    with open(input_path, "r", encoding="utf-8") as f:
        listings = json.load(f)

    if not isinstance(listings, list):
        print("住まいサーフィン: 入力が配列ではありません", file=sys.stderr)
        return

    radar_count = 0
    for listing in listings:
        had_radar = listing.get("ss_radar_data") is not None
        _finalize_radar_data(listing, property_type=property_type)
        if not had_radar and listing.get("ss_radar_data") is not None:
            radar_count += 1

    # 原子的書き込み
    tmp_path = output_path_p.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp_path.replace(output_path_p)

    print(f"レーダーデータ補完: {radar_count}件生成（既存フィールドから）", file=sys.stderr)


def main() -> None:
    ap = argparse.ArgumentParser(description="住まいサーフィンの評価データで物件 JSON を enrichment する")
    ap.add_argument("--input", "-i", required=True, help="入力 JSON ファイル")
    ap.add_argument("--output", "-o", required=True, help="出力 JSON ファイル")
    ap.add_argument("--property-type", choices=["chuko", "shinchiku"], default=None,
                    help="物件タイプ（未指定時はファイル名から自動判定）")
    ap.add_argument("--finalize-radar-only", action="store_true",
                    help="Web スクレイピングなしでレーダーデータのみ補完する（SUMAI_USER/PASS 不要）")
    ap.add_argument("--browser", action="store_true",
                    help="ブラウザ自動化で追加データを取得（中古: 割安判定、新築: カスタムシミュレーション）")
    ap.add_argument("--browser-only", action="store_true",
                    help="ブラウザ自動化のみ実行（requests ベースの enrichment をスキップ）")
    args = ap.parse_args()

    # 物件タイプの自動判定
    if args.property_type:
        prop_type = args.property_type
    elif "shinchiku" in args.input.lower():
        prop_type = "shinchiku"
    else:
        prop_type = "chuko"

    print(f"住まいサーフィン: 物件タイプ = {prop_type}", file=sys.stderr)

    if args.finalize_radar_only:
        finalize_radar_only(args.input, args.output, property_type=prop_type)
        return

    user = os.environ.get("SUMAI_USER", "")
    password = os.environ.get("SUMAI_PASS", "")

    if not user or not password:
        print("住まいサーフィン: SUMAI_USER / SUMAI_PASS が未設定のためスキップ", file=sys.stderr)
        # 認証不要のレーダーデータ補完だけ実行
        finalize_radar_only(args.input, args.output, property_type=prop_type)
        return

    # ── requests ベースの enrichment ──
    if not args.browser_only:
        session = _create_session()

        if not login(session, user, password):
            print("住まいサーフィン: ログインに失敗したためスキップ", file=sys.stderr)
            # ログイン失敗でもレーダーデータ補完は実行
            finalize_radar_only(args.input, args.output, property_type=prop_type)
            # ブラウザ enrichment はログイン失敗でもスキップ
            return

        enrich_listings(args.input, args.output, session, property_type=prop_type)

    # ── ブラウザ自動化 enrichment ──
    if args.browser or args.browser_only:
        try:
            from sumai_surfin_browser import browser_enrich_listings
            print("ブラウザ自動化 enrichment を実行中...", file=sys.stderr)
            browser_enrich_listings(
                input_path=args.input if args.browser_only else args.output,
                output_path=args.output,
                property_type=prop_type,
                user=user,
                password=password,
            )
        except ImportError:
            print(
                "ブラウザ enrichment: playwright が未インストールのためスキップ\n"
                "  pip install playwright && playwright install chromium",
                file=sys.stderr,
            )


if __name__ == "__main__":
    main()
