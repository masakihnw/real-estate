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
from urllib.parse import quote_plus

import requests
from bs4 import BeautifulSoup

from config import REQUEST_DELAY_SEC, USER_AGENT

# ──────────────────────────── 定数 ────────────────────────────

BASE_URL = "https://www.sumai-surfin.com"
LOGIN_URL = "https://account.sumai-surfin.com/login"
SEARCH_URL = f"{BASE_URL}/search/"

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


def login(session: requests.Session, user: str, password: str) -> bool:
    """住まいサーフィンにログインし、セッション Cookie を取得する。"""
    try:
        # ログインページを取得して CSRF トークン等を確認
        resp = session.get(LOGIN_URL, timeout=30)
        resp.raise_for_status()

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

        # ユーザー名・パスワードフィールド名を検出
        username_field = "username"
        password_field = "password"
        if form_tag:
            for inp in form_tag.find_all("input"):
                t = inp.get("type", "").lower()
                n = inp.get("name", "")
                if t == "text" and n:
                    username_field = n
                elif t == "password" and n:
                    password_field = n

        form_data[username_field] = user
        form_data[password_field] = password

        # POST でログイン
        action = LOGIN_URL
        if form_tag and form_tag.get("action"):
            a = form_tag["action"]
            if a.startswith("http"):
                action = a
            elif a.startswith("/"):
                action = "https://account.sumai-surfin.com" + a

        resp2 = session.post(action, data=form_data, timeout=30, allow_redirects=True)

        # ログイン成功判定: マイページ or ログアウトリンクがある
        if "ログアウト" in resp2.text or "mypage" in resp2.url:
            print("住まいサーフィン: ログイン成功", file=sys.stderr)
            return True

        print("住まいサーフィン: ログイン失敗（ログアウトリンクが見つかりません）", file=sys.stderr)
        return False

    except Exception as e:
        print(f"住まいサーフィン: ログインエラー: {e}", file=sys.stderr)
        return False


# ──────────────────────────── キャッシュ ────────────────────────────

def load_cache() -> dict:
    if CACHE_PATH.exists():
        try:
            return json.loads(CACHE_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def save_cache(cache: dict) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    CACHE_PATH.write_text(json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8")


# ──────────────────────────── 検索 ────────────────────────────

def search_property(session: requests.Session, name: str, cache: dict) -> Optional[str]:
    """
    物件名で住まいサーフィンを検索し、/re/{id}/ の URL を返す。
    見つからなければ None。
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
        params = {"q": name}
        resp = session.get(SEARCH_URL, params=params, timeout=30)
        resp.raise_for_status()

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
            return best_url

        # 見つからなかった
        cache[clean_name] = None
        return None

    except Exception as e:
        print(f"住まいサーフィン: 検索エラー ({name}): {e}", file=sys.stderr)
        return None


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

def parse_property_page(session: requests.Session, url: str) -> dict:
    """
    住まいサーフィンの物件ページ (/re/{id}/) をパースし、
    評価データの dict を返す。
    """
    result: dict = {"ss_sumai_surfin_url": url}

    time.sleep(DELAY)

    try:
        resp = session.get(url, timeout=30)
        resp.raise_for_status()
        html = resp.text
        soup = BeautifulSoup(html, "lxml")
    except Exception as e:
        print(f"住まいサーフィン: ページ取得エラー ({url}): {e}", file=sys.stderr)
        return result

    # ── 沖式儲かる確率 ──
    profit_pct = _extract_profit_pct(soup, html)
    if profit_pct is not None:
        result["ss_profit_pct"] = profit_pct

    # ── 沖式新築時価 / 沖式時価 (70m2換算) ──
    oki_price = _extract_oki_price(soup, html)
    if oki_price is not None:
        result["ss_oki_price_70m2"] = oki_price

    # ── 割安判定 ──
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

    # ── 値上がりシミュレーション (5年後/10年後 × ベスト/標準/ワースト) ──
    sim_data = _extract_simulation_data(soup, html)
    result.update(sim_data)

    return result


def _extract_profit_pct(soup: BeautifulSoup, html: str) -> Optional[int]:
    """沖式儲かる確率（%）を抽出。"""
    # テキストから "儲かる確率" 付近の数値を探す
    # パターン1: "XX%" の大きな数字表示
    m = re.search(r"儲かる確率.*?(\d{1,3})\s*%", html, re.DOTALL)
    if m:
        return int(m.group(1))

    # パターン2: class で探す
    for el in soup.find_all(string=re.compile(r"儲かる確率")):
        parent = el.find_parent()
        if parent:
            # 近傍の数値を探す
            container = parent.find_parent()
            if container:
                num = re.search(r"(\d{1,3})\s*[%％]", container.get_text())
                if num:
                    return int(num.group(1))
    return None


def _extract_oki_price(soup: BeautifulSoup, html: str) -> Optional[int]:
    """沖式新築時価 or 沖式時価 (万円) を抽出。"""
    patterns = [
        r"沖式新築時価.*?(\d[\d,]+)\s*万円",
        r"沖式時価.*?(\d[\d,]+)\s*万円",
        r"沖式中古時価.*?(\d[\d,]+)\s*万円",
    ]
    for pat in patterns:
        m = re.search(pat, html, re.DOTALL)
        if m:
            return int(m.group(1).replace(",", ""))
    return None


def _extract_value_judgment(soup: BeautifulSoup, html: str) -> Optional[str]:
    """割安判定を抽出。"""
    for keyword in ("割安", "適正", "割高"):
        # 判定結果としてキーワードが含まれるか
        m = re.search(rf"割安判定.*?({keyword})", html, re.DOTALL)
        if m:
            return keyword
    # 「お買い得」系の表現
    if re.search(r"お買い得", html):
        return "割安"
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
    """中古値上がり率 (%) を抽出。プラスなら +18.5、マイナスなら -3.2 のような float。"""
    # パターン1: "中古値上がり率" 付近の "XX%" を探す
    m = re.search(r"中古値上がり率.*?([+-]?\d+(?:\.\d+)?)\s*[%％]", html, re.DOTALL)
    if m:
        return float(m.group(1))

    # パターン2: テーブル行の中で「値上がり率」ラベルの隣セルから取得
    for el in soup.find_all(string=re.compile(r"値上がり率")):
        parent = el.find_parent("td") or el.find_parent("th") or el.find_parent()
        if parent:
            # 隣の td を探す
            next_td = parent.find_next_sibling("td")
            if next_td:
                num = re.search(r"([+-]?\d+(?:\.\d+)?)\s*[%％]", next_td.get_text())
                if num:
                    return float(num.group(1))
            # 親コンテナ全体から数値を探す
            container = parent.find_parent()
            if container:
                num = re.search(r"([+-]?\d+(?:\.\d+)?)\s*[%％]", container.get_text())
                if num:
                    return float(num.group(1))

    # パターン3: "XX%" 表記でリンクテキスト内の値上がり率表
    for row in soup.find_all("tr"):
        cells = row.find_all(["td", "th"])
        for i, cell in enumerate(cells):
            if "値上がり率" in cell.get_text():
                # 同じ行の次セルまたは同じセル内
                for j in range(i + 1, len(cells)):
                    num = re.search(r"([+-]?\d+(?:\.\d+)?)\s*[%％]", cells[j].get_text())
                    if num:
                        return float(num.group(1))
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
    """購入判定（"購入が望ましい" 等）を抽出。"""
    # パターン1: "購入判定" の近くのテキスト
    m = re.search(r"購入判定.*?(購入[^\s<]{1,20})", html, re.DOTALL)
    if m:
        return m.group(1).strip()

    # パターン2: テーブルや見出しの隣
    for el in soup.find_all(string=re.compile(r"購入判定")):
        parent = el.find_parent()
        if parent:
            # 隣の要素を探す
            sibling = parent.find_next_sibling()
            if sibling:
                text = sibling.get_text(strip=True)
                if text:
                    return text
            # 同じ親内のテキスト
            container = parent.find_parent()
            if container:
                text = container.get_text(strip=True)
                # "購入判定" を除去して残りを取得
                text = text.replace("購入判定", "").strip()
                if text:
                    return text
    return None


def _extract_simulation_data(soup: BeautifulSoup, html: str) -> dict:
    """
    値上がりシミュレーションテーブルのデータを抽出。
    返却例: {
        "ss_sim_best_5yr": 7344,
        "ss_sim_best_10yr": 7788,
        "ss_sim_standard_5yr": 6744,
        "ss_sim_standard_10yr": 6588,
        "ss_sim_worst_5yr": 6144,
        "ss_sim_worst_10yr": 5388,
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
            else:
                continue

            # 5年後 (cells[1]) と 10年後 (cells[2]) の値を抽出
            for idx, suffix in [(1, "5yr"), (2, "10yr")]:
                if idx < len(cells):
                    val_text = cells[idx].get_text(strip=True)
                    num = re.search(r"([\d,]+)\s*万円", val_text)
                    if num:
                        result[f"ss_sim_{case_key}_{suffix}"] = int(num.group(1).replace(",", ""))

    # テーブルが見つからなかった場合、正規表現でフォールバック
    if not result:
        case_patterns = {
            "best": r"ベストケース",
            "standard": r"標準ケース",
            "worst": r"ワーストケース",
        }
        for case_key, case_pat in case_patterns.items():
            # "ベストケース ... 7,344万円 ... 7,788万円" のようなパターン
            m = re.search(
                case_pat + r".*?([\d,]+)\s*万円.*?([\d,]+)\s*万円",
                html, re.DOTALL,
            )
            if m:
                result[f"ss_sim_{case_key}_5yr"] = int(m.group(1).replace(",", ""))
                result[f"ss_sim_{case_key}_10yr"] = int(m.group(2).replace(",", ""))

    return result


# ──────────────────────────── メイン処理 ────────────────────────────

def enrich_listings(input_path: str, output_path: str, session: requests.Session) -> None:
    """JSON ファイルの各物件に住まいサーフィンの評価データを付加する。"""

    with open(input_path, "r", encoding="utf-8") as f:
        listings = json.load(f)

    if not isinstance(listings, list):
        print("住まいサーフィン: 入力が配列ではありません", file=sys.stderr)
        return

    cache = load_cache()
    enriched_count = 0
    skip_count = 0

    for i, listing in enumerate(listings):
        name = listing.get("name", "")
        if not name:
            continue

        # 既に enrichment 済みならスキップ
        if listing.get("ss_profit_pct") is not None or listing.get("ss_oki_price_70m2") is not None:
            skip_count += 1
            continue

        print(f"  [{i+1}/{len(listings)}] {name} ...", end=" ", file=sys.stderr)

        # 検索
        prop_url = search_property(session, name, cache)
        if not prop_url:
            print("見つかりません", file=sys.stderr)
            continue

        # ページパース
        data = parse_property_page(session, prop_url)

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
            if data.get("ss_favorite_count") is not None:
                parts.append(f"お気に入り: {data['ss_favorite_count']}点")
            print(f"OK ({', '.join(parts) or 'URL取得'})", file=sys.stderr)
        else:
            print("データなし", file=sys.stderr)

    # キャッシュ保存
    save_cache(cache)

    # 出力
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)

    print(f"住まいサーフィン enrichment 完了: {enriched_count}件追加, {skip_count}件スキップ", file=sys.stderr)


def main() -> None:
    ap = argparse.ArgumentParser(description="住まいサーフィンの評価データで物件 JSON を enrichment する")
    ap.add_argument("--input", "-i", required=True, help="入力 JSON ファイル")
    ap.add_argument("--output", "-o", required=True, help="出力 JSON ファイル")
    args = ap.parse_args()

    user = os.environ.get("SUMAI_USER", "")
    password = os.environ.get("SUMAI_PASS", "")

    if not user or not password:
        print("住まいサーフィン: SUMAI_USER / SUMAI_PASS が未設定のためスキップ", file=sys.stderr)
        return

    session = _create_session()

    if not login(session, user, password):
        print("住まいサーフィン: ログインに失敗したためスキップ", file=sys.stderr)
        return

    enrich_listings(args.input, args.output, session)


if __name__ == "__main__":
    main()
