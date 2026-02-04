"""
物件の最寄駅から指定オフィスまでの通勤時間を表示する。
data/commute_<key>.json（駅名 → 分数）を参照。未登録の駅は「(概算)」で
徒歩分数＋最寄り駅から会社最寄り駅までの時間＋会社最寄り駅から会社までの徒歩 を表示。
複数駅が使える場合は最短路線での通勤時間目安を返す。
"""

import json
import re
from pathlib import Path
from typing import Optional, Tuple, List

# 未登録駅時の概算: 最寄り駅→会社最寄り駅のデフォルト分数＋会社最寄り駅→会社の徒歩
# M3: 虎ノ門駅が会社最寄り（0分）、PG: 半蔵門駅が会社最寄り（2分）
ESTIMATE_STATION_TO_OFFICE_M3_MIN = 30
ESTIMATE_OFFICE_STATION_WALK_M3_MIN = 0
ESTIMATE_STATION_TO_OFFICE_PG_MIN = 30
ESTIMATE_OFFICE_STATION_WALK_PG_MIN = 2

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"

# 通勤先: key -> (表示ラベル, 最寄駅メモ)
COMMUTE_DESTINATIONS = {
    "m3career": ("エムスリーキャリア", "虎ノ門"),   # 港区虎ノ門4-1-28 虎ノ門タワーズオフィス
    "playground": ("playground(一番町)", "半蔵門"),  # 千代田区一番町4-6 一番町中央ビル
}

_cache: dict[str, dict[str, int]] = {}


def _load_commute_json(key: str) -> dict[str, int]:
    """data/commute_<key>.json を読み込む。"""
    if key in _cache:
        return _cache[key]
    path = DATA_DIR / f"commute_{key}.json"
    if not path.exists():
        _cache[key] = {}
        return _cache[key]
    try:
        with open(path, "r", encoding="utf-8") as f:
            _cache[key] = json.load(f)
        return _cache[key]
    except Exception:
        _cache[key] = {}
        return _cache[key]


def _lookup_minutes(data: dict[str, int], station_name: str) -> Optional[int]:
    """
    JSONのキーと駅名を照合する。完全一致のほか、「駅」の有無で揃えて照合する。
    """
    s = (station_name or "").strip()
    if not s:
        return None
    # 完全一致
    if s in data:
        return data[s]
    # 「駅」を除いた名前で照合（物件は「東新宿」、JSONは「東新宿」の想定）
    s_no_eki = s.rstrip("駅").strip() if s.endswith("駅") else s
    if s_no_eki in data:
        return data[s_no_eki]
    # JSONキー側の「駅」を除いて照合
    for key, val in data.items():
        key_no_eki = key.rstrip("駅").strip() if key.endswith("駅") else key
        if key_no_eki == s or key_no_eki == s_no_eki:
            return val
    return None


def get_commute_minutes(station_name: str, destination_key: str) -> Optional[int]:
    """
    駅名から指定オフィスまでの通勤時間（分）を返す。
    未登録・不正な駅名は None。
    """
    if not station_name or station_name == "(駅情報なし)":
        return None
    data = _load_commute_json(destination_key)
    return _lookup_minutes(data, station_name)


def parse_station_walk_pairs(
    station_line: str,
    fallback_walk_min: Optional[int] = None,
) -> List[Tuple[str, Optional[int]]]:
    """
    物件の station_line から「駅名」と「徒歩分数」の組を全て抽出する。
    例: "ＪＲ山手線「目白」徒歩4分／ＪＲ山手線「大塚」徒歩8分" → [("目白", 4), ("大塚", 8)]
    1駅のみで徒歩が無い場合は fallback_walk_min を先頭にだけ使う。
    """
    if not station_line or not station_line.strip():
        return []
    parts = re.split(r"[／/]", station_line.strip())
    result: List[Tuple[str, Optional[int]]] = []
    used_fallback = False
    for part in parts:
        seg = part.strip()
        if not seg:
            continue
        walk_m = re.search(r"徒歩\s*約?\s*(\d+)\s*分", seg)
        walk_val: Optional[int] = int(walk_m.group(1)) if walk_m else None
        if walk_val is None and fallback_walk_min is not None and not used_fallback:
            walk_val = fallback_walk_min
            used_fallback = True
        station_name = ""
        bracket = re.search(r"[「『]([^」』]+)[」』]", seg)
        if bracket:
            station_name = bracket.group(1).strip()
        if not station_name:
            station_m = re.search(r"([^\s/]+駅)", seg)
            if station_m:
                station_name = station_m.group(1).strip()
        if not station_name:
            first_word = (seg[:30] or "").strip()
            if first_word and first_word != "(駅情報なし)":
                station_name = first_word
        if station_name:
            result.append((station_name, walk_val))
    return result


def format_all_station_walk(
    station_line: str,
    fallback_walk_min: Optional[int] = None,
) -> str:
    """
    物件に記載されている全駅と徒歩分数を1つの文字列で返す。
    例: "目白 徒歩4分 / 大塚 徒歩8分"。1駅のみの場合は "目白 徒歩4分"。
    """
    pairs = parse_station_walk_pairs(station_line, fallback_walk_min)
    if not pairs:
        if fallback_walk_min is not None:
            return f"徒歩{fallback_walk_min}分"
        return "-"
    return " / ".join(
        f"{name} 徒歩{w}分" if w is not None else name
        for name, w in pairs
    )


def extract_station_names(station_line: str) -> list[str]:
    """
    station_line から利用可能な駅名を複数抽出する。
    「」『』内の名前と「〇〇駅」形式を取得し、重複を除いて返す。
    """
    if not station_line or not station_line.strip():
        return []
    names: set[str] = set()
    # 「」『』内（例: 東京メトロ日比谷線「八丁堀」徒歩5分）
    for m in re.finditer(r"[「『]([^」』]+)[」』]", station_line):
        names.add(m.group(1).strip())
    # 〇〇駅 形式（例: 有楽町駅徒歩10分）
    for m in re.finditer(r"([^\s/]+駅)", station_line):
        names.add(m.group(1).strip())
    # 1つも取れない場合は先頭25文字を1駅として扱う（表示用ラベルと一致させる）
    if not names:
        first = (station_line.strip()[:25] or "").strip()
        if first and first != "(駅情報なし)":
            names.add(first)
    return list(names)


def get_commute_display(station_name: str) -> tuple[Optional[int], Optional[int]]:
    """駅名から M3・playground の通勤分数を返す。(m3_min, pg_min)。"""
    m3 = get_commute_minutes(station_name, "m3career")
    pg = get_commute_minutes(station_name, "playground")
    return (m3, pg)


def get_commute_display_best(station_line: str) -> tuple[Optional[int], Optional[int]]:
    """
    複数駅が使える場合、最短路線での通勤時間目安を返す。
    station_line から駅名を複数抽出し、M3・PGそれぞれで最短の分数を返す。(m3_min, pg_min)。
    """
    stations = extract_station_names(station_line)
    if not stations:
        return (None, None)
    m3_list: list[int] = []
    pg_list: list[int] = []
    for name in stations:
        m3 = get_commute_minutes(name, "m3career")
        pg = get_commute_minutes(name, "playground")
        if m3 is not None:
            m3_list.append(m3)
        if pg is not None:
            pg_list.append(pg)
    m3_best = min(m3_list) if m3_list else None
    pg_best = min(pg_list) if pg_list else None
    return (m3_best, pg_best)


def format_commute_minutes(minutes: Optional[int]) -> str:
    """分数を「○分」または「-」で返す。"""
    if minutes is None:
        return "-"
    return f"{minutes}分"


def get_commute_display_with_estimate(
    station_line: str,
    walk_min: Optional[int],
) -> Tuple[str, str]:
    """
    M3・PG の通勤時間表示文字列を返す。(m3_str, pg_str)。
    いずれもドアtoドア（物件→最寄駅の徒歩＋最寄駅→オフィス）で表示する。
    JSON に駅が登録されていれば 徒歩＋駅→オフィス で「○分」、未登録なら
    (概算) 徒歩＋最寄り駅→会社最寄り駅＋会社最寄り駅→会社の徒歩 を表示する。
    """
    m3_min, pg_min = get_commute_display_best(station_line or "")
    walk = walk_min if walk_min is not None else 0

    if m3_min is not None:
        m3_str = f"{walk + m3_min}分"
    else:
        est = walk + ESTIMATE_STATION_TO_OFFICE_M3_MIN + ESTIMATE_OFFICE_STATION_WALK_M3_MIN
        m3_str = f"(概算){est}分"

    if pg_min is not None:
        pg_str = f"{walk + pg_min}分"
    else:
        est = walk + ESTIMATE_STATION_TO_OFFICE_PG_MIN + ESTIMATE_OFFICE_STATION_WALK_PG_MIN
        pg_str = f"(概算){est}分"

    return (m3_str, pg_str)


def get_commute_total_minutes(
    station_line: str,
    walk_min: Optional[int],
) -> Tuple[Optional[int], Optional[int]]:
    """
    M3・PG のドアtoドア通勤分数を返す。(m3_total_min, pg_total_min)。
    未登録駅の場合は概算（徒歩＋最寄り→会社最寄り＋会社最寄り→会社）を返す。
    """
    m3_min, pg_min = get_commute_display_best(station_line or "")
    walk = walk_min if walk_min is not None else 0

    if m3_min is not None:
        m3_total = walk + m3_min
    else:
        m3_total = walk + ESTIMATE_STATION_TO_OFFICE_M3_MIN + ESTIMATE_OFFICE_STATION_WALK_M3_MIN

    if pg_min is not None:
        pg_total = walk + pg_min
    else:
        pg_total = walk + ESTIMATE_STATION_TO_OFFICE_PG_MIN + ESTIMATE_OFFICE_STATION_WALK_PG_MIN

    return (m3_total, pg_total)


def get_destination_labels() -> tuple[str, str]:
    """レポート用の通勤先ラベル。(M3のラベル, playgroundのラベル)。"""
    return (COMMUTE_DESTINATIONS["m3career"][0], COMMUTE_DESTINATIONS["playground"][0])
