#!/usr/bin/env python3
"""
全物件の沖式中古時価70m2換算を検索結果一覧ページから再取得するワンタイムスクリプト。

背景:
  物件詳細ページのヘルプ文（用語説明）に含まれる例示値（「例：7,000万円」等）を
  正規表現が誤取得していた問題への対策。検索結果一覧の物件カードに表示される
  沖式中古時価70m2換算が正しい値であるため、全物件をこのソースで更新する。

使い方:
  cd scraping-tool
  python3 scripts/refresh_oki_prices.py

環境変数:
  SUMAI_USER  -- ログインユーザー名
  SUMAI_PASS  -- ログインパスワード
  （.env ファイルから自動読み込み）
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

# scraping-tool/ をインポートパスに追加
SCRAPING_TOOL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRAPING_TOOL_DIR))

import requests
from bs4 import BeautifulSoup

from sumai_surfin_enricher import (
    _create_session,
    _request_with_retry,
    login,
    load_cache,
    save_cache,
    _normalize_name,
    _build_search_keyword,
    _find_property_card_text,
    DELAY,
    SEARCH_RESULT_URL,
    TOKYO_PREFECTURE_ID,
)

RESULTS_PATH = SCRAPING_TOOL_DIR / "results" / "latest.json"


def _load_env() -> None:
    """scraping-tool/.env からの環境変数読み込み（dotenv 未使用環境向け）。"""
    env_path = SCRAPING_TOOL_DIR / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip()
            if key and key not in os.environ:
                os.environ[key] = val


def _extract_oki_price_from_card(card_text: str) -> int | None:
    """カードテキストから沖式中古時価70m2換算（万円）を抽出。"""
    m = re.search(r"沖式中古時価\s*70\s*m?\s*[2²]?\s*換算\s*([\d,]+)\s*万円", card_text)
    if m:
        val = int(m.group(1).replace(",", ""))
        if val >= 1500:
            return val
    return None


def main() -> None:
    _load_env()

    user = os.environ.get("SUMAI_USER", "")
    password = os.environ.get("SUMAI_PASS", "")
    if not user or not password:
        print("エラー: SUMAI_USER / SUMAI_PASS を設定してください", file=sys.stderr)
        sys.exit(1)

    session = _create_session()
    if not login(session, user, password):
        print("エラー: ログイン失敗", file=sys.stderr)
        sys.exit(1)

    # データ読み込み
    with open(RESULTS_PATH, "r", encoding="utf-8") as f:
        listings = json.load(f)
    cache = load_cache()

    updated = 0
    unchanged = 0
    not_found = 0
    no_url = 0
    errors = 0
    total = len(listings)

    for i, listing in enumerate(listings):
        name = listing.get("name", "")
        if not name:
            continue

        clean_name = _normalize_name(name)
        cached_url = cache.get(clean_name)

        if not cached_url:
            no_url += 1
            continue

        # re_id を取得
        re_match = re.search(r"/re/(\d+)/?", cached_url)
        if not re_match:
            no_url += 1
            continue
        re_id = re_match.group(1)

        # 検索キーワード
        search_keyword = _build_search_keyword(name)

        time.sleep(DELAY)

        try:
            params = {
                "prefecture_id": TOKYO_PREFECTURE_ID,
                "keyword": search_keyword,
            }
            resp = _request_with_retry(session, "GET", SEARCH_RESULT_URL, params=params)
            if resp is None:
                print(f"  ! [{i+1}/{total}] {name} — HTTP エラー", file=sys.stderr)
                errors += 1
                continue

            soup = BeautifulSoup(resp.text, "lxml")

            # カード要素を特定して沖式中古時価を抽出
            card_text = _find_property_card_text(soup, re_id)
            if not card_text:
                print(f"  × [{i+1}/{total}] {name} — カード未検出", file=sys.stderr)
                not_found += 1
                continue

            val = _extract_oki_price_from_card(card_text)
            if val is None:
                print(f"  × [{i+1}/{total}] {name} — 沖式中古時価未検出", file=sys.stderr)
                not_found += 1
                continue

            old_val = listing.get("ss_oki_price_70m2")
            listing["ss_oki_price_70m2"] = val

            # __inline キャッシュも更新
            inline_key = clean_name + "__inline"
            inline_data = cache.get(inline_key, {})
            if not isinstance(inline_data, dict):
                inline_data = {}
            inline_data["oki_price_70m2"] = val
            cache[inline_key] = inline_data

            # 値上がり率もカードから取得（ボーナス）
            m_rate = re.search(r"値上(?:が|り)り率\s*(\d+(?:\.\d+)?)\s*[%％]", card_text)
            if m_rate:
                inline_data["appreciation_rate"] = float(m_rate.group(1))

            if old_val != val:
                diff = f"{old_val} → {val}" if old_val else f"新規 {val}"
                print(f"  ✓ [{i+1}/{total}] {name} — {diff} 万円", file=sys.stderr)
                updated += 1
            else:
                print(f"  = [{i+1}/{total}] {name} — {val} 万円（変更なし）", file=sys.stderr)
                unchanged += 1

        except Exception as e:
            print(f"  ! [{i+1}/{total}] {name} — エラー: {e}", file=sys.stderr)
            errors += 1

        # 進捗: 20件ごとにサマリー
        processed = updated + unchanged + not_found + errors
        if processed > 0 and processed % 20 == 0:
            print(
                f"  --- 進捗: {processed}/{total} 件処理済"
                f" (更新: {updated}, 変更なし: {unchanged},"
                f" 未検出: {not_found}, エラー: {errors}) ---",
                file=sys.stderr,
            )

    # 保存
    with open(RESULTS_PATH, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
        f.write("\n")

    save_cache(cache)

    print(
        f"\n完了:"
        f" 更新 {updated} 件,"
        f" 変更なし {unchanged} 件,"
        f" 未検出 {not_found} 件,"
        f" URL未キャッシュ {no_url} 件,"
        f" エラー {errors} 件",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
