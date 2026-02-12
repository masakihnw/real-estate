#!/usr/bin/env python3
"""
東京都 駅別 中古マンション m²単価推移チャート生成ツール。

usage:
  python3 scripts/station_price_trend_chart.py

入力:
  data/station_price_history.json — 駅別の年次m²単価データ
  data/area_coefficients.csv     — 駅のティア分類（station_name, area_rank）
  data/reinfolib_trends.json     — 既存キャッシュ（区データ比較用）

出力:
  results/station_price_trend.html — インタラクティブなChart.jsチャート
"""

import csv
import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.dirname(SCRIPT_DIR)
DATA_DIR = os.path.join(BASE_DIR, "data")
RESULTS_DIR = os.path.join(BASE_DIR, "results")

STATION_HISTORY_FILE = os.path.join(DATA_DIR, "station_price_history.json")
AREA_COEFFICIENTS_FILE = os.path.join(DATA_DIR, "area_coefficients.csv")
TRENDS_FILE = os.path.join(DATA_DIR, "reinfolib_trends.json")
OUTPUT_FILE = os.path.join(RESULTS_DIR, "station_price_trend.html")

# ティア別カラーパレット
TIER_COLORS = {
    "Tier1": "rgb(220, 38, 38)",   # red
    "Tier2": "rgb(37, 99, 235)",   # blue
    "Tier3": "rgb(22, 163, 74)",   # green
    "Other": "rgb(107, 114, 128)", # gray
}

# デフォルト表示件数（主要20駅）
TOP_N_DEFAULT = 20


def load_station_tiers() -> Dict[str, str]:
    """area_coefficients.csv から station_name -> area_rank（Tier1/2/3）を読み込む。"""
    tiers: Dict[str, str] = {}
    if not os.path.exists(AREA_COEFFICIENTS_FILE):
        return tiers
    with open(AREA_COEFFICIENTS_FILE, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row.get("station_name", "").strip()
            rank = row.get("area_rank", "").strip()
            if name and rank:
                tiers[name] = rank
    return tiers


def load_station_history() -> Dict[str, Any]:
    """station_price_history.json を読み込む。"""
    if os.path.exists(STATION_HISTORY_FILE):
        with open(STATION_HISTORY_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def load_trends_data() -> Dict[str, Any]:
    """reinfolib_trends.json を読み込む（区データ比較用）。"""
    if os.path.exists(TRENDS_FILE):
        with open(TRENDS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def get_station_tier(station_name: str, tiers: Dict[str, str]) -> str:
    """駅名からティアを返す。area_coefficients.csv にない場合は Other。"""
    return tiers.get(station_name, "Other")


def get_station_color(tier: str) -> str:
    """ティアから色を返す。"""
    return TIER_COLORS.get(tier, TIER_COLORS["Other"])


def normalize_station_data(
    raw: Dict[str, Any],
    tiers: Dict[str, str],
) -> Tuple[Dict[str, Dict[str, Optional[int]]], List[str], Dict[str, Any]]:
    """
    駅別データを正規化し、years を year ラベルで並べた形に。
    戻り値: (station_name -> {year: median_m2_price}, years_sorted, station_meta)
    """
    result: Dict[str, Dict[str, Optional[int]]] = {}
    meta: Dict[str, Any] = {}

    by_station = raw.get("by_station", {})
    all_years: set[str] = set()

    for station_name, data in by_station.items():
        years_data = data.get("years", {})
        if not years_data:
            continue
        all_years.update(years_data.keys())

        result[station_name] = {}
        for year, yinfo in years_data.items():
            median = yinfo.get("median_m2_price")
            result[station_name][year] = median if median is not None else None

        meta[station_name] = {
            "ward": data.get("ward", ""),
            "lines": data.get("lines", []),
            "tier": get_station_tier(station_name, tiers),
        }

    years_sorted = sorted(all_years)

    # データが存在しない年（例: 現在年の途中）を除外
    years_sorted = [
        y for y in years_sorted
        if sum(1 for s in result.values() if s.get(y) is not None) >= 10
    ]

    return result, years_sorted, meta


def get_top_stations_by_latest(
    data: Dict[str, Dict[str, Optional[int]]],
    years: List[str],
    n: int = TOP_N_DEFAULT,
) -> List[str]:
    """最新年の m²単価で上位 n 駅を返す。"""
    latest_year = years[-1] if years else None
    if not latest_year:
        return []

    with_price = [
        (name, data[name].get(latest_year))
        for name in data
        if data[name].get(latest_year) is not None
    ]
    sorted_stations = sorted(with_price, key=lambda x: x[1] or 0, reverse=True)
    return [name for name, _ in sorted_stations[:n]]


def generate_html(
    data: Dict[str, Dict[str, Optional[int]]],
    years: List[str],
    meta: Dict[str, Any],
    tiers: Dict[str, str],
) -> str:
    """Chart.js を使ったインタラクティブHTMLを生成。"""

    top_stations = get_top_stations_by_latest(data, years, TOP_N_DEFAULT)

    # 全駅をティア順にソート（Tier1, Tier2, Tier3, Other）、同ティア内は最新価格降順
    latest_year = years[-1] if years else ""
    def sort_key(name: str) -> Tuple[int, int]:
        t = meta.get(name, {}).get("tier", "Other")
        tier_order = {"Tier1": 0, "Tier2": 1, "Tier3": 2, "Other": 3}
        t_idx = tier_order.get(t, 4)
        latest = data.get(name, {}).get(latest_year) or 0
        return (t_idx, -latest)

    sorted_stations = sorted(data.keys(), key=sort_key)

    # データセット構築
    datasets = []
    for station_name in sorted_stations:
        station_data = data[station_name]
        tier = meta.get(station_name, {}).get("tier", "Other")
        color = get_station_color(tier)
        lines = meta.get(station_name, {}).get("lines", [])

        values = []
        for y in years:
            val = station_data.get(y)
            values.append(val if val is not None else None)

        lines_str = "、".join(lines) if lines else ""

        dataset = {
            "label": station_name,
            "data": values,
            "borderColor": color,
            "backgroundColor": color.replace("rgb", "rgba").replace(")", ", 0.1)"),
            "borderWidth": 2,
            "pointRadius": 3,
            "pointHoverRadius": 6,
            "tension": 0.3,
            "fill": False,
            "tier": tier,
            "inTop20": station_name in top_stations,
            "lines": lines_str,
        }
        datasets.append(dataset)

    # サマリーテーブル用（変動率順）
    first_year = years[0] if years else ""
    summary_rows = []
    for station_name in sorted_stations:
        station_data = data[station_name]
        latest_val = station_data.get(latest_year)
        first_val = station_data.get(first_year)
        change_pct = None
        if latest_val and first_val and first_val > 0:
            change_pct = round((latest_val - first_val) / first_val * 100, 1)
        tier = meta.get(station_name, {}).get("tier", "Other")
        color = get_station_color(tier)
        lines = meta.get(station_name, {}).get("lines", [])
        lines_str = "、".join(lines) if lines else ""
        summary_rows.append({
            "station": station_name,
            "tier": tier,
            "latest": latest_val,
            "first": first_val,
            "change_pct": change_pct,
            "color": color,
            "lines": lines_str,
        })

    # 変動率順
    summary_rows_sorted = sorted(
        summary_rows,
        key=lambda r: -(r["change_pct"] or -999),
    )

    # datasets JSON
    datasets_json_parts = []
    for ds in datasets:
        vals = ds["data"]
        data_str = "[" + ", ".join(str(v) if v is not None else "null" for v in vals) + "]"
        label_esc = json.dumps(ds["label"])
        lines_esc = json.dumps(ds["lines"])
        datasets_json_parts.append(f"""{{
          label: {label_esc},
          data: {data_str},
          borderColor: '{ds["borderColor"]}',
          backgroundColor: '{ds["backgroundColor"]}',
          borderWidth: 2,
          pointRadius: 3,
          pointHoverRadius: 6,
          tension: 0.3,
          fill: false,
          tier: '{ds["tier"]}',
          inTop20: {str(ds["inTop20"]).lower()},
          lines: {lines_esc},
          hidden: true
        }}""")

    datasets_js = ",\n        ".join(datasets_json_parts)
    labels_js = json.dumps(years, ensure_ascii=False)

    # サマリーテーブルHTML
    summary_html_rows = []
    for row in summary_rows_sorted:
        latest_str = f"¥{row['latest']:,.0f}" if row["latest"] else "N/A"
        first_str = f"¥{row['first']:,.0f}" if row["first"] else "N/A"
        change_str = ""
        change_class = ""
        if row["change_pct"] is not None:
            if row["change_pct"] > 0:
                change_str = f"+{row['change_pct']}%"
                change_class = "positive"
            else:
                change_str = f"{row['change_pct']}%"
                change_class = "negative"
        summary_html_rows.append(f"""
          <tr data-station="{row['station']}">
            <td><span class="color-dot" style="background:{row['color']}"></span>{row['station']}</td>
            <td class="tier-cell">{row['tier']}</td>
            <td class="lines-cell">{row['lines']}</td>
            <td class="number">{first_str}</td>
            <td class="number">{latest_str}</td>
            <td class="number {change_class}">{change_str}</td>
          </tr>""")

    summary_table_body = "\n".join(summary_html_rows)

    html = f"""<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>東京都 駅別 中古マンション m²単価推移（年次）</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Hiragino Sans', sans-serif;
      background: #f8fafc;
      color: #1e293b;
      padding: 20px;
      max-width: 1400px;
      margin: 0 auto;
    }}
    h1 {{
      font-size: 1.5rem;
      font-weight: 700;
      margin-bottom: 4px;
      color: #0f172a;
    }}
    .subtitle {{
      font-size: 0.85rem;
      color: #64748b;
      margin-bottom: 20px;
    }}
    .chart-container {{
      background: white;
      border-radius: 12px;
      padding: 24px;
      box-shadow: 0 1px 3px rgba(0,0,0,0.1);
      margin-bottom: 20px;
      position: relative;
    }}
    .chart-wrapper {{
      height: 500px;
      position: relative;
    }}
    .filter-bar {{
      display: flex;
      gap: 8px;
      margin-bottom: 16px;
      flex-wrap: wrap;
      align-items: center;
    }}
    .filter-btn {{
      padding: 6px 14px;
      border: 1px solid #e2e8f0;
      border-radius: 8px;
      background: white;
      cursor: pointer;
      font-size: 0.8rem;
      font-weight: 500;
      color: #475569;
      transition: all 0.15s;
    }}
    .filter-btn:hover {{
      background: #f1f5f9;
    }}
    .filter-btn.active {{
      background: #1e293b;
      color: white;
      border-color: #1e293b;
    }}
    .filter-label {{
      font-size: 0.75rem;
      color: #94a3b8;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }}
    .search-box {{
      padding: 8px 12px;
      border: 1px solid #e2e8f0;
      border-radius: 8px;
      font-size: 0.85rem;
      color: #1e293b;
      background: white;
      min-width: 200px;
    }}
    .search-box:focus {{
      outline: 2px solid #3b82f6;
      outline-offset: 0;
    }}
    .search-box::placeholder {{
      color: #94a3b8;
    }}
    .summary-section {{
      background: white;
      border-radius: 12px;
      padding: 24px;
      box-shadow: 0 1px 3px rgba(0,0,0,0.1);
    }}
    .summary-section h2 {{
      font-size: 1.1rem;
      font-weight: 600;
      margin-bottom: 16px;
      color: #0f172a;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      font-size: 0.85rem;
    }}
    th {{
      text-align: left;
      padding: 10px 12px;
      border-bottom: 2px solid #e2e8f0;
      color: #64748b;
      font-weight: 600;
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }}
    th.number {{ text-align: right; }}
    td {{
      padding: 8px 12px;
      border-bottom: 1px solid #f1f5f9;
    }}
    td.number {{ text-align: right; font-variant-numeric: tabular-nums; }}
    td.positive {{ color: #dc2626; font-weight: 600; }}
    td.negative {{ color: #2563eb; font-weight: 600; }}
    .color-dot {{
      display: inline-block;
      width: 10px;
      height: 10px;
      border-radius: 50%;
      margin-right: 8px;
      vertical-align: middle;
    }}
    .tier-cell {{
      color: #94a3b8;
      font-size: 0.75rem;
    }}
    .lines-cell {{
      font-size: 0.75rem;
      color: #64748b;
      max-width: 180px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }}
    tr:hover {{
      background: #f8fafc;
    }}
    tr.hidden {{
      display: none;
    }}
    .note {{
      margin-top: 16px;
      font-size: 0.75rem;
      color: #94a3b8;
    }}
    .stats-row {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 12px;
      margin-bottom: 20px;
    }}
    .stat-card {{
      background: white;
      border-radius: 10px;
      padding: 16px;
      box-shadow: 0 1px 3px rgba(0,0,0,0.1);
    }}
    .stat-label {{
      font-size: 0.7rem;
      color: #94a3b8;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 4px;
    }}
    .stat-value {{
      font-size: 1.3rem;
      font-weight: 700;
      color: #0f172a;
    }}
    .stat-sub {{
      font-size: 0.75rem;
      color: #64748b;
      margin-top: 2px;
    }}
  </style>
</head>
<body>
  <h1>東京都 駅別 中古マンション m&sup2;単価推移（年次）</h1>
  <p class="subtitle">成約価格ベース &middot; 国土交通省 不動産情報ライブラリ &middot; {first_year}〜{latest_year}</p>

  <div class="stats-row" id="statsRow"></div>

  <div class="chart-container">
    <div class="filter-bar">
      <span class="filter-label">表示:</span>
      <button class="filter-btn" data-filter="all">全駅</button>
      <button class="filter-btn" data-filter="Tier1">Tier1</button>
      <button class="filter-btn" data-filter="Tier2">Tier2</button>
      <button class="filter-btn" data-filter="Tier3">Tier3</button>
      <button class="filter-btn active" data-filter="top20">主要20駅</button>
      <input type="text" class="search-box" id="searchInput" placeholder="駅名で検索…">
    </div>
    <div class="chart-wrapper">
      <canvas id="trendChart"></canvas>
    </div>
  </div>

  <div class="summary-section">
    <h2>駅別サマリー（変動率順）</h2>
    <table>
      <thead>
        <tr>
          <th>駅</th>
          <th>ティア</th>
          <th>路線</th>
          <th class="number">{first_year}</th>
          <th class="number">{latest_year}</th>
          <th class="number">変動率</th>
        </tr>
      </thead>
      <tbody>
        {summary_table_body}
      </tbody>
    </table>
    <p class="note">※ 成約価格（中古マンション等）の中央値。データソース: 国土交通省 不動産情報ライブラリ</p>
  </div>

  <script>
    const labels = {labels_js};
    const allDatasets = [
        {datasets_js}
    ];

    // Stats
    const statsRow = document.getElementById('statsRow');
    const latest = allDatasets.map(d => ({{ name: d.label, val: d.data[d.data.length - 1], tier: d.tier }})).filter(d => d.val !== null);
    const avgAll = latest.length ? Math.round(latest.reduce((s, d) => s + d.val, 0) / latest.length) : 0;
    const maxStation = latest.length ? latest.reduce((a, b) => a.val > b.val ? a : b) : {{ name: '-', val: 0 }};
    const minStation = latest.length ? latest.reduce((a, b) => a.val < b.val ? a : b) : {{ name: '-', val: 0 }};

    const firstVals = allDatasets.map(d => ({{ name: d.label, first: d.data.find(v => v !== null), last: d.data[d.data.length - 1] }})).filter(d => d.first !== null && d.last !== null);
    const avgChange = firstVals.length ? Math.round(firstVals.reduce((s, d) => s + (d.last - d.first) / d.first * 100, 0) / firstVals.length * 10) / 10 : 0;

    statsRow.innerHTML = `
      <div class="stat-card">
        <div class="stat-label">平均 m&sup2;単価</div>
        <div class="stat-value">&yen;${{avgAll.toLocaleString()}}</div>
        <div class="stat-sub">直近年</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">最高値</div>
        <div class="stat-value">&yen;${{maxStation.val.toLocaleString()}}</div>
        <div class="stat-sub">${{maxStation.name}}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">最安値</div>
        <div class="stat-value">&yen;${{minStation.val.toLocaleString()}}</div>
        <div class="stat-sub">${{minStation.name}}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">平均変動率</div>
        <div class="stat-value">${{avgChange > 0 ? '+' : ''}}${{avgChange}}%</div>
        <div class="stat-sub">${{labels[0]}}→${{labels[labels.length-1]}}</div>
      </div>
    `;

    const ctx = document.getElementById('trendChart').getContext('2d');
    const chart = new Chart(ctx, {{
      type: 'line',
      data: {{
        labels: labels,
        datasets: allDatasets
      }},
      options: {{
        responsive: true,
        maintainAspectRatio: false,
        interaction: {{
          mode: 'index',
          intersect: false,
        }},
        plugins: {{
          legend: {{
            position: 'right',
            labels: {{
              usePointStyle: true,
              pointStyle: 'circle',
              padding: 8,
              font: {{ size: 11 }}
            }}
          }},
          tooltip: {{
            backgroundColor: 'rgba(15, 23, 42, 0.95)',
            titleFont: {{ size: 13 }},
            bodyFont: {{ size: 12 }},
            padding: 12,
            cornerRadius: 8,
            callbacks: {{
              label: function(ctx) {{
                const val = ctx.parsed.y;
                const lines = ctx.dataset.lines || '';
                return val ? `${{ctx.dataset.label}}${{lines ? ' (' + lines + ')' : ''}}: ¥${{val.toLocaleString()}}/m²` : '';
              }}
            }}
          }}
        }},
        scales: {{
          x: {{
            grid: {{ display: false }},
            ticks: {{ font: {{ size: 11 }} }}
          }},
          y: {{
            title: {{
              display: true,
              text: 'm² 単価（円）',
              font: {{ size: 12 }}
            }},
            ticks: {{
              callback: function(value) {{
                return '¥' + (value / 10000).toFixed(0) + '万';
              }},
              font: {{ size: 11 }}
            }},
            grid: {{
              color: 'rgba(0,0,0,0.05)'
            }}
          }}
        }},
        spanGaps: true
      }}
    }});

    function applyFilter() {{
      const filter = document.querySelector('.filter-btn.active')?.dataset?.filter || 'top20';
      const search = (document.getElementById('searchInput').value || '').trim().toLowerCase();
      chart.data.datasets.forEach(ds => {{
        const matchesFilter = filter === 'all' || filter === ds.tier || (filter === 'top20' && ds.inTop20);
        const matchesSearch = !search || ds.label.toLowerCase().includes(search);
        ds.hidden = !(matchesFilter && matchesSearch);
      }});
      chart.update();
    }}

    function updateTableSearch() {{
      const search = (document.getElementById('searchInput').value || '').trim().toLowerCase();
      document.querySelectorAll('.summary-section tbody tr').forEach(tr => {{
        const station = tr.dataset.station || '';
        tr.classList.toggle('hidden', search && !station.toLowerCase().includes(search));
      }});
    }}

    document.querySelectorAll('.filter-btn').forEach(btn => {{
      btn.addEventListener('click', () => {{
        document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        applyFilter();
      }});
    }});

    document.getElementById('searchInput').addEventListener('input', () => {{
      applyFilter();
      updateTableSearch();
    }});

    // 初期表示: 主要20駅
    applyFilter();
  </script>
</body>
</html>"""
    return html


def main():
    print("=== 東京都 駅別 m²単価推移チャート生成 ===", file=sys.stderr)

    tiers = load_station_tiers()
    raw = load_station_history()
    _ = load_trends_data()  # 将来の比較用に読み込み可能

    if not raw.get("by_station"):
        print("エラー: station_price_history.json が見つからないか、by_station が空です", file=sys.stderr)
        print("データファイル: " + STATION_HISTORY_FILE, file=sys.stderr)
        sys.exit(1)

    data, years, meta = normalize_station_data(raw, tiers)

    print(f"駅数: {len(data)}", file=sys.stderr)
    print(f"期間: {years[0]} 〜 {years[-1]} ({len(years)} 年)", file=sys.stderr)

    html = generate_html(data, years, meta, tiers)

    os.makedirs(RESULTS_DIR, exist_ok=True)
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"出力: {OUTPUT_FILE}", file=sys.stderr)


if __name__ == "__main__":
    main()
