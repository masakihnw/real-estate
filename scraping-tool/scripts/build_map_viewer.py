#!/usr/bin/env python3
"""
results/latest.json（中古）と latest_shinchiku.json（新築）を読み、住所をジオコーディングして地図用HTMLを生成する。
出力: results/map_viewer.html （ブラウザで開くと物件がマッピングされた地図が表示される）

使い方:
  python scripts/build_map_viewer.py [results/latest.json]
  python scripts/build_map_viewer.py results/latest.json --shinchiku results/latest_shinchiku.json
  python scripts/build_map_viewer.py --output custom_map.html
  python scripts/build_map_viewer.py --previous results/previous.json --limit 20

ピン色: 青=中古、緑=新築。前回結果（--previous）があれば新規物件にはポップアップで🆕バッジを表示。
初回は住所のジオコーディングで時間がかかります。結果は data/geocode_cache.json にキャッシュされ、次回以降は高速です。
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_JSON = ROOT / "results" / "latest.json"
DEFAULT_OUTPUT = ROOT / "results" / "map_viewer.html"

# geocode は build_map_viewer の親ディレクトリから import
sys.path.insert(0, str(ROOT))
from scripts.geocode import geocode
from report_utils import compare_listings, identity_key

from logger import get_logger
logger = get_logger(__name__)


def build_map_data(
    listings: list,
    previous_listings: Optional[list] = None,
) -> list:
    """
    物件リストから地図用データを生成。
    同一住所は1ピンにまとめ、価格・間取りが違う複数件はポップアップで一覧表示。
    ピン色は property_type で決定: 青=中古(chuko)、緑=新築(shinchiku)。
    previous があれば新規物件にポップアップで🆕バッジを表示。
    """
    new_keys = set()
    if previous_listings:
        diff = compare_listings(listings, previous_listings)
        for r in diff.get("new", []):
            new_keys.add(identity_key(r))

    # 住所ごとにグループ化（同じ住所 = 同じ建物・1ピン）
    # ss_address（住まいサーフィンの詳細住所）があればジオコーディング精度向上に使用するが、
    # グループ化は元の address で行う（同一物件の重複検知のため）
    by_address = {}
    for r in listings:
        address = (r.get("address") or "").strip()
        if not address:
            continue
        by_address.setdefault(address, []).append(r)

    result = []
    for address, group in by_address.items():
        # ss_address（番地レベルの詳細住所）があれば優先的にジオコーディング
        ss_addr = (group[0].get("ss_address") or "").strip()
        coords = None
        if ss_addr:
            coords = geocode(ss_addr)
        if not coords:
            coords = geocode(address)
        if not coords:
            continue
        lat, lon = coords
        items = []
        any_new = False
        has_shinchiku = False
        for r in group:
            is_new = identity_key(r) in new_keys
            if is_new:
                any_new = True
            prop_type = (r.get("property_type") or "chuko").strip()
            if prop_type == "shinchiku":
                has_shinchiku = True
            items.append({
                "name": (r.get("name") or "").strip(),
                "url": (r.get("url") or "").strip(),
                "price_man": r.get("price_man"),
                "layout": (r.get("layout") or "").strip(),
                "area_m2": r.get("area_m2"),
                "station_line": (r.get("station_line") or "").strip(),
                "walk_min": r.get("walk_min"),
                "built_year": r.get("built_year"),
                "is_new": is_new,
                "property_type": prop_type,
            })
        result.append({
            "lat": lat,
            "lon": lon,
            "address": address,
            "listings": items,
            "is_new": any_new,
            "is_shinchiku": has_shinchiku,
        })
    return result


def html_content(map_data: list[dict]) -> str:
    """Leaflet でマーカーを表示する HTML を返す。データは埋め込みで file:// でも動作。"""
    # </script> が JSON に含まれると HTML が壊れるためエスケープし、script type=application/json で渡す
    data_json = json.dumps(map_data, ensure_ascii=False).replace("</", "<\\/")
    return f"""<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>物件マップ - 取得物件の位置</title>
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" crossorigin="" />
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js" crossorigin=""></script>
  <style>
    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
    body {{ font-family: "Hiragino Sans", "Hiragino Kaku Gothic ProN", sans-serif; }}
    #map {{ width: 100%; height: 100vh; min-height: 360px; }}
    .leaflet-popup-content-wrapper {{ border-radius: 8px; }}
    .popup-name {{ font-weight: bold; margin-bottom: 4px; font-size: 14px; }}
    .popup-row {{ font-size: 12px; color: #444; margin: 2px 0; }}
    .popup-link {{ margin-top: 8px; }}
    .popup-link a {{ color: #0066cc; text-decoration: none; font-size: 12px; }}
    .popup-link a:hover {{ text-decoration: underline; }}
    .popup-new {{ background: #dcfce7; color: #166534; font-size: 11px; padding: 2px 6px; border-radius: 4px; margin-bottom: 4px; display: inline-block; }}
    .popup-address {{ font-size: 12px; color: #555; margin-bottom: 8px; }}
    .popup-item {{ border-top: 1px solid #eee; padding-top: 6px; margin-top: 6px; }}
    .popup-item:first-of-type {{ border-top: none; padding-top: 0; margin-top: 0; }}
    #legend {{ position: absolute; bottom: 24px; left: 12px; z-index: 1000; background: #fff; padding: 8px 12px; border-radius: 8px; box-shadow: 0 1px 4px rgba(0,0,0,0.2); font-size: 12px; }}
    #legend .item {{ margin: 4px 0; display: flex; align-items: center; gap: 8px; }}
    #legend .pin {{ width: 14px; height: 14px; border-radius: 50% 50% 50% 0; transform: rotate(-45deg); border: 2px solid #fff; box-shadow: 0 1px 2px rgba(0,0,0,0.2); }}
    #legend .pin-chuko {{ background: #3b82f6; }}
    #legend .pin-shinchiku {{ background: #22c55e; }}
    #hint {{ position: absolute; top: 12px; left: 12px; right: 12px; z-index: 1000; background: #fffbeb; border: 1px solid #fcd34d; border-radius: 8px; padding: 10px 12px; font-size: 12px; color: #92400e; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
  </style>
</head>
<body>
  <div id="hint">※Slackアプリ内で開くと地図が表示されないことがあります。リンクを長押し→「ブラウザで開く」で Safari や Chrome から開くと表示されます。</div>
  <div id="map"></div>
  <div id="legend">
    <div class="item"><span class="pin pin-chuko"></span> 中古</div>
    <div class="item"><span class="pin pin-shinchiku"></span> 新築</div>
  </div>
  <script type="application/json" id="map-data">{data_json}</script>
  <script>
    function escapeHtml(s) {{
      const div = document.createElement("div");
      div.textContent = s;
      return div.innerHTML;
    }}
    function escapeAttr(s) {{
      return String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }}
    function initMap() {{
      if (typeof L === "undefined") {{
        document.getElementById("map").innerHTML = "<div style=\\"padding:24px;text-align:center;color:#666;\\">地図を表示できません。Slackアプリ内では表示されないため、リンクを長押し→「ブラウザで開く」で Safari や Chrome から開いてください。</div>";
        return;
      }}
      const MAP_DATA = JSON.parse(document.getElementById("map-data").textContent);
      const center = MAP_DATA.length
        ? [MAP_DATA.reduce((s, p) => s + p.lat, 0) / MAP_DATA.length, MAP_DATA.reduce((s, p) => s + p.lon, 0) / MAP_DATA.length]
        : [35.68, 139.75];
      const map = L.map("map").setView(center, 12);
      L.tileLayer("https://{{s}}.tile.openstreetmap.org/{{z}}/{{x}}/{{y}}.png", {{
        attribution: "&copy; <a href=\\"https://www.openstreetmap.org/copyright\\">OpenStreetMap</a>"
      }}).addTo(map);
      const chukoIcon = L.divIcon({{ className: "pin-chuko", html: "<div style=\\"background:#3b82f6;width:24px;height:24px;border-radius:50% 50% 50% 0;transform:rotate(-45deg);border:2px solid #fff;box-shadow:0 1px 3px rgba(0,0,0,0.3)\\"></div>", iconSize: [24, 24], iconAnchor: [12, 24] }});
      const shinchikuIcon = L.divIcon({{ className: "pin-shinchiku", html: "<div style=\\"background:#22c55e;width:24px;height:24px;border-radius:50% 50% 50% 0;transform:rotate(-45deg);border:2px solid #fff;box-shadow:0 1px 3px rgba(0,0,0,0.3)\\"></div>", iconSize: [24, 24], iconAnchor: [12, 24] }});
      MAP_DATA.forEach(function(p) {{
        const addrHtml = "<div class=\\"popup-address\\">" + escapeHtml(p.address) + "</div>";
        let itemsHtml = "";
        (p.listings || [p]).forEach(function(item, i) {{
          const price = item.price_man != null ? item.price_man + "万円" : "-";
          const area = item.area_m2 != null ? item.area_m2 + "m²" : "-";
          const walk = item.walk_min != null ? item.walk_min + "分" : "";
          const newBadge = item.is_new ? "<span class=\\"popup-new\\">🆕</span> " : "";
          itemsHtml += "<div class=\\"popup-item\\">" + newBadge +
            "<div class=\\"popup-name\\">" + escapeHtml(item.name || "(名前なし)") + "</div>" +
            "<div class=\\"popup-row\\">" + price + " · " + (item.layout || "-") + " · " + area + "</div>" +
            (item.station_line ? "<div class=\\"popup-row\\">" + escapeHtml(item.station_line) + (walk ? " 徒歩" + walk : "") + "</div>" : "") +
            (item.url ? "<div class=\\"popup-link\\"><a href=\\"" + escapeAttr(item.url) + "\\" target=\\"_blank\\" rel=\\"noopener\\">詳細を開く</a></div>" : "") + "</div>";
        }});
        const content = addrHtml + itemsHtml;
        const marker = L.marker([p.lat, p.lon], {{ icon: p.is_shinchiku ? shinchikuIcon : chukoIcon }});
        marker.addTo(map).bindPopup(content);
      }});
      setTimeout(function() {{ if (map && map.invalidateSize) map.invalidateSize(); }}, 300);
    }}
    if (document.readyState === "complete") {{
      initMap();
    }} else {{
      window.addEventListener("load", initMap);
    }}
  </script>
</body>
</html>
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="物件JSONをジオコーディングして地図用HTMLを生成する。",
        epilog="ピン色: 青=中古、緑=新築。前回結果（--previous）があれば新規物件に🆕バッジを表示。",
    )
    parser.add_argument(
        "json_path",
        nargs="?",
        type=Path,
        default=DEFAULT_JSON,
        help=f"物件JSONファイルのパス（デフォルト: {DEFAULT_JSON}）",
    )
    parser.add_argument(
        "--previous",
        "-p",
        type=Path,
        metavar="PATH",
        help="前回の物件JSON（比較用。省略時は json_path の親ディレクトリの previous.json）",
    )
    parser.add_argument(
        "--shinchiku",
        "-s",
        type=Path,
        metavar="PATH",
        help="新築物件JSONのパス（中古JSONに結合して地図化）",
    )
    parser.add_argument(
        "--limit",
        "-n",
        type=int,
        metavar="N",
        help="先頭N件のみ処理（テスト用）",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=DEFAULT_OUTPUT,
        metavar="PATH",
        help=f"出力HTMLのパス（デフォルト: {DEFAULT_OUTPUT}）",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    json_path = args.json_path
    previous_path = args.previous if args.previous is not None else json_path.parent / "previous.json"
    shinchiku_path_str = str(args.shinchiku) if args.shinchiku else None
    limit = args.limit
    output_html = args.output
    if not json_path.exists():
        logger.error(f"Error: {json_path} not found")
        sys.exit(1)
    with open(json_path, encoding="utf-8") as f:
        listings = json.load(f)
    if not isinstance(listings, list):
        logger.error("Error: JSON must be an array of listings")
        sys.exit(1)

    # 新築 JSON を読み込んで結合
    shinchiku_count = 0
    if shinchiku_path_str:
        shinchiku_path = Path(shinchiku_path_str)
        if shinchiku_path.exists():
            try:
                with open(shinchiku_path, encoding="utf-8") as f:
                    shinchiku_data = json.load(f)
                if isinstance(shinchiku_data, list):
                    shinchiku_count = len(shinchiku_data)
                    listings = listings + shinchiku_data
                    logger.error(f"Loaded {shinchiku_count} shinchiku listings from {shinchiku_path}")
            except Exception as e:
                print(f"Warning: failed to load shinchiku JSON: {e}")
        else:
            logger.warning(f"Warning: shinchiku file not found: {shinchiku_path}")

    if limit is not None:
        listings = listings[:limit]
        print(f"Limit: using first {limit} listings.")
    previous_listings = None
    if previous_path.exists():
        try:
            with open(previous_path, encoding="utf-8") as f:
                prev = json.load(f)
            if isinstance(prev, list):
                previous_listings = prev
                print(f"Comparing with previous: {previous_path} ({len(previous_listings)} listings)")
        except Exception:
            pass
    # --shinchiku 指定時は previous_shinchiku.json も比較対象に含める
    # これがないと新築物件が毎回全件 is_new=true になる
    if shinchiku_path_str:
        prev_shinchiku_path = previous_path.parent / "previous_shinchiku.json"
        if prev_shinchiku_path.exists():
            try:
                with open(prev_shinchiku_path, encoding="utf-8") as f:
                    prev_shin = json.load(f)
                if isinstance(prev_shin, list):
                    if previous_listings is None:
                        previous_listings = prev_shin
                    else:
                        previous_listings = previous_listings + prev_shin
                    print(f"Comparing with previous shinchiku: {prev_shinchiku_path} ({len(prev_shin)} listings)")
            except Exception:
                pass
    print(f"Loading {len(listings)} listings ({len(listings) - shinchiku_count} chuko + {shinchiku_count} shinchiku)...")
    map_data = build_map_data(listings, previous_listings)
    new_count = sum(1 for p in map_data if p.get("is_new"))
    shinchiku_pin_count = sum(1 for p in map_data if p.get("is_shinchiku"))
    print(f"Geocoded {len(map_data)} locations (skipped {len(listings) - len(map_data)} without coordinates).")
    print(f"Pins: {len(map_data) - shinchiku_pin_count} chuko (blue) + {shinchiku_pin_count} shinchiku (green)")
    if new_count:
        print(f"Newly added listings (🆕 badge): {new_count}")
    output_html.parent.mkdir(parents=True, exist_ok=True)
    with open(output_html, "w", encoding="utf-8") as f:
        f.write(html_content(map_data))
    print(f"Wrote {output_html}")
    print("Open the file in a browser to view the map.")


if __name__ == "__main__":
    main()
