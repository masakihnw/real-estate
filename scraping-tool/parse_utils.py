"""
共通パーサー関数。

suumo_scraper / suumo_shinchiku_scraper / homes_scraper / homes_shinchiku_scraper で
共有するテキスト解析ユーティリティ。純粋関数のみ（副作用なし）。
"""

import re
from typing import Optional


# ──────────────────────────── 価格 ────────────────────────────


def parse_price(s: str) -> Optional[int]:
    """「1080万円」「1億4360万円」などから万円単位の数値を返す。"""
    if not s:
        return None
    s = s.replace(",", "").strip()
    if "億" in s:
        m = re.search(r"([0-9.]+)億([0-9.]*)\s*万?", s)
        if m:
            oku = float(m.group(1))
            man = float(m.group(2) or 0)
            return int(oku * 10000 + man)
    m = re.search(r"([0-9.,]+)\s*万", s)
    if m:
        return int(float(m.group(1).replace(",", "")))
    return None


def parse_price_range(text: str) -> tuple[Optional[int], Optional[int]]:
    """新築の価格表記をパース。
    例:
      "4900万円台～8300万円台／予定" → (4900, 8300)
      "価格未定" → (None, None)
      "7440万円～9670万円" → (7440, 9670)
      "9900万円台～2億1000万円台／予定" → (9900, 21000)
      "1億1880万円～1億3480万円" → (11880, 13480)
      "3700万円台～6500万円台／予定 （第1期1次）" → (3700, 6500)
    """
    if not text or "価格未定" in text:
        return (None, None)
    text = text.replace(",", "").replace("（", "(").replace("）", ")")
    # 期情報を除去
    text = re.sub(r"\(.*?\)", "", text).strip()
    # "／予定" "/ 予定" を除去
    text = re.sub(r"[／/]\s*予定", "", text).strip()

    def _parse_single_price(s: str) -> Optional[int]:
        """単一の価格表記をパース。"""
        s = s.strip()
        if not s:
            return None
        if "億" in s:
            m = re.search(r"([0-9.]+)\s*億\s*([0-9.]*)\s*万?円?\s*台?", s)
            if m:
                oku = float(m.group(1))
                man = float(m.group(2) or 0)
                return int(oku * 10000 + man)
        m = re.search(r"([0-9.,]+)\s*万\s*円?\s*台?", s)
        if m:
            return int(float(m.group(1).replace(",", "")))
        return None

    # "～" or "〜" で分割
    parts = re.split(r"[～〜]", text, maxsplit=1)
    if len(parts) == 2:
        lo = _parse_single_price(parts[0])
        hi = _parse_single_price(parts[1])
        return (lo, hi)
    else:
        val = _parse_single_price(text)
        return (val, val)


# ──────────────────────────── 面積 ────────────────────────────


def parse_area_m2(s: str) -> Optional[float]:
    """「48.93m2」「48.93㎡」「48.93m2（14.80坪）」などから数値を返す。"""
    if not s:
        return None
    # 数値＋単位の形のみマッチ（「㎡」単体だと group(1) が None になるため数値を必須に）
    m = re.search(r"([0-9.]+)\s*(?:m2|㎡|m\s*2)", s, re.I)
    if m and m.group(1) is not None:
        return float(m.group(1))
    return None


def parse_area_range(text: str) -> tuple[Optional[float], Optional[float]]:
    """面積幅をパース。"60.71m2～85.42m2" → (60.71, 85.42)。"""
    if not text:
        return (None, None)
    vals = re.findall(r"([0-9.]+)\s*(?:m2|㎡|m\s*2)", text, re.I)
    if len(vals) >= 2:
        return (float(vals[0]), float(vals[1]))
    elif len(vals) == 1:
        return (float(vals[0]), float(vals[0]))
    return (None, None)


# ──────────────────────────── 徒歩 ────────────────────────────


def parse_walk_min(s: str) -> Optional[int]:
    """「徒歩4分」「徒歩約3分」などから分を返す（最初のマッチ）。中古スクレイパー用。"""
    if not s:
        return None
    m = re.search(r"徒歩\s*約?\s*([0-9]+)\s*分", s)
    if m:
        return int(m.group(1))
    return None


def parse_walk_min_best(text: str) -> Optional[int]:
    """「徒歩4分」「徒歩9分～10分」から最小値を返す。新築スクレイパー用（複数駅表記対応）。"""
    if not text:
        return None
    vals = re.findall(r"徒歩\s*約?\s*([0-9]+)\s*分", text)
    if vals:
        return min(int(v) for v in vals)
    return None


# ──────────────────────────── 築年 ────────────────────────────


def parse_built_year(s: str) -> Optional[int]:
    """「1976年3月」「2020年6月」などから年を返す。"""
    if not s:
        return None
    m = re.search(r"([0-9]{4})\s*年", s)
    if m:
        return int(m.group(1))
    return None


# ──────────────────────────── 階数 ────────────────────────────


def parse_floor_position(s: str) -> Optional[int]:
    """「5階」「13階」などから所在階を返す（「階建」は除外）。"""
    if not s:
        return None
    m = re.search(r"(\d+)\s*階(?!建)", s)
    return int(m.group(1)) if m else None


def parse_floor_total(s: str) -> Optional[int]:
    """「10階建」「6階建て」などから建物階数を返す。中古スクレイパー用。"""
    if not s:
        return None
    m = re.search(r"(\d+)\s*階\s*建(?:て)?", s)
    return int(m.group(1)) if m else None


def parse_floor_total_lenient(text: str) -> Optional[int]:
    """「地上20階」「29階建」から階数を抽出。新築スクレイパー用（「建」がオプション、「地上」プレフィックス対応）。"""
    if not text:
        return None
    m = re.search(r"(?:地上\s*)?(\d+)\s*階(?:\s*建)?", text)
    return int(m.group(1)) if m else None


# ──────────────────────────── 総戸数 ────────────────────────────


def parse_total_units(text: str) -> Optional[int]:
    """「全394邸」「総戸数143戸」「全50邸」から総戸数を抽出。新築・汎用版。"""
    if not text:
        return None
    m = re.search(r"(?:全|総戸数\s*)(\d+)\s*(?:邸|戸)", text)
    return int(m.group(1)) if m else None


def parse_total_units_strict(text: str) -> Optional[int]:
    """「総戸数143戸」から総戸数を抽出。中古HOME'S用（「全N邸」はマッチしない）。"""
    if not text:
        return None
    m = re.search(r"総戸数\s*(\d+)\s*戸", text)
    return int(m.group(1)) if m else None


# ──────────────────────────── 間取り ────────────────────────────


def layout_ok(layout: str) -> bool:
    """2LDK〜3LDK 系か（2DK/3DK 含む）。中古スクレイパー用。"""
    if not layout:
        return False
    layout = layout.strip()
    return any(
        layout.startswith(p) or layout.replace("K", "DK").startswith(p)
        for p in ("2", "3")
    ) and ("LDK" in layout or "DK" in layout or "K" in layout)


def layout_range_ok(layout: str) -> bool:
    """間取り幅が条件に合うか。新築スクレイパー用。
    "2LDK～4LDK" のような幅表記の場合、2LDK or 3LDK が含まれればOK。
    "1LDK～4LDK" も 2LDK, 3LDK を含むのでOK。
    """
    if not layout:
        return True  # 間取り不明は通過
    layout = layout.strip()
    # 幅表記の場合: 先頭の数字と末尾の数字を取得してレンジチェック
    nums = re.findall(r"(\d+)\s*[LDKS]", layout)
    if nums:
        num_range = [int(n) for n in nums]
        lo = min(num_range)
        hi = max(num_range)
        # config の LAYOUT_PREFIX_OK は ("2", "3") なので、レンジ内に 2 or 3 があればOK
        return lo <= 3 and hi >= 2
    # 単一間取り
    return layout.startswith("2") or layout.startswith("3")


# ──────────────────────────── 権利形態 ────────────────────────────


def parse_ownership(text: str) -> Optional[str]:
    """テキストから権利形態（所有権・借地権・底地権等）を抽出。中古HOME'S用。"""
    if not text or not text.strip():
        return None
    m = re.search(r"(所有権|借地権|底地権|普通借地権|定期借地権)", (text or "").strip())
    return m.group(1).strip() if m else None


def parse_ownership_from_text(text: str) -> Optional[str]:
    """テキストから権利形態を推定。新築用。
    新築では「所有権」「定期借地権」「一般定期借地権」などが記載されることが多い。
    """
    if not text:
        return None
    # 「権利形態」ラベル近辺から取得を試みる
    m = re.search(r"権利(?:形態)?[：:\s]*([^\n,、]+)", text)
    if m:
        val = m.group(1).strip()
        if val and len(val) <= 50:
            return val
    # ラベルなしで直接パターンマッチ
    for pattern in [
        r"(一般定期借地権[^\n]*)",
        r"(定期借地権[^\n]*)",
        r"(普通借地権[^\n]*)",
        r"(旧法借地権[^\n]*)",
    ]:
        m = re.search(pattern, text)
        if m:
            val = m.group(1).strip()
            if val and len(val) <= 80:
                return val
    # 「所有権」は単独で出現することが多い
    if re.search(r"所有権", text):
        return "所有権"
    return None
