#!/usr/bin/env python3
"""
東京23区 中古マンション 平米単価の推移チャート生成ツール。

usage:
  python3 scripts/ward_price_trend_chart.py

入力:
  data/ward_price_history.json  — 全23区の四半期別m²単価データ
  data/reinfolib_trends.json    — 既存キャッシュ（2024-2025）

出力:
  results/ward_price_trend.html — インタラクティブなChart.jsチャート
"""

import json
import os
import statistics
import sys
from typing import Any, Dict, List, Optional

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.dirname(SCRIPT_DIR)
DATA_DIR = os.path.join(BASE_DIR, "data")
RESULTS_DIR = os.path.join(BASE_DIR, "results")

HISTORY_FILE = os.path.join(DATA_DIR, "ward_price_history.json")
TRENDS_FILE = os.path.join(DATA_DIR, "reinfolib_trends.json")
OUTPUT_FILE = os.path.join(RESULTS_DIR, "ward_price_trend.html")

WARD_CODE_TO_NAME = {
    "13101": "千代田区", "13102": "中央区", "13103": "港区",
    "13104": "新宿区", "13105": "文京区", "13106": "台東区",
    "13107": "墨田区", "13108": "江東区", "13109": "品川区",
    "13110": "目黒区", "13111": "大田区", "13112": "世田谷区",
    "13113": "渋谷区", "13114": "中野区", "13115": "杉並区",
    "13116": "豊島区", "13117": "北区", "13118": "荒川区",
    "13119": "板橋区", "13120": "練馬区", "13121": "足立区",
    "13122": "葛飾区", "13123": "江戸川区",
}

# 区のティア分類（価格帯で色分け）
WARD_TIERS = {
    "Tier1_都心": ["千代田区", "中央区", "港区", "渋谷区"],
    "Tier2_準都心": ["新宿区", "文京区", "台東区", "目黒区", "品川区", "豊島区"],
    "Tier3_城西・城南": ["世田谷区", "中野区", "杉並区", "大田区"],
    "Tier4_城北・城東": ["墨田区", "江東区", "北区", "荒川区", "板橋区", "練馬区", "足立区", "葛飾区", "江戸川区"],
}

# ティア別カラーパレット
TIER_COLORS = {
    "Tier1_都心": [
        "rgb(220, 38, 38)",    # red
        "rgb(239, 68, 68)",
        "rgb(185, 28, 28)",
        "rgb(248, 113, 113)",
    ],
    "Tier2_準都心": [
        "rgb(37, 99, 235)",    # blue
        "rgb(59, 130, 246)",
        "rgb(29, 78, 216)",
        "rgb(96, 165, 250)",
        "rgb(30, 64, 175)",
        "rgb(147, 197, 253)",
    ],
    "Tier3_城西・城南": [
        "rgb(22, 163, 74)",    # green
        "rgb(34, 197, 94)",
        "rgb(21, 128, 61)",
        "rgb(74, 222, 128)",
    ],
    "Tier4_城北・城東": [
        "rgb(161, 98, 7)",     # amber/brown
        "rgb(202, 138, 4)",
        "rgb(146, 64, 14)",
        "rgb(234, 179, 8)",
        "rgb(120, 53, 15)",
        "rgb(251, 191, 36)",
        "rgb(180, 83, 9)",
        "rgb(253, 224, 71)",
        "rgb(113, 63, 18)",
    ],
}


def load_trends_data() -> Dict[str, Any]:
    """既存のtrends.jsonを読み込む。"""
    if os.path.exists(TRENDS_FILE):
        with open(TRENDS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def load_history_data() -> Dict[str, Any]:
    """ward_price_history.json を読み込む。"""
    if os.path.exists(HISTORY_FILE):
        with open(HISTORY_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def merge_data(trends: Dict, history: Dict) -> Dict[str, Dict[str, Optional[int]]]:
    """
    trends と history を統合し、ward_name → {quarter_label: median_m2_price} の形に。
    """
    result: Dict[str, Dict[str, Optional[int]]] = {}

    # 1) trends.json のデータ
    if "by_ward" in trends:
        for ward_name, ward_data in trends["by_ward"].items():
            if ward_name not in result:
                result[ward_name] = {}
            for q in ward_data.get("quarters", []):
                qlabel = q["quarter"]
                median = q.get("median_m2_price")
                if median is not None:
                    result[ward_name][qlabel] = median

    # 2) history.json のデータ（古い期間のもの。trends と重複する場合はtrendsを優先）
    if "by_ward" in history:
        for ward_name, ward_data in history["by_ward"].items():
            if ward_name not in result:
                result[ward_name] = {}
            for qlabel, qinfo in ward_data.get("quarters", {}).items():
                if qlabel not in result[ward_name]:
                    median = qinfo.get("median_m2_price")
                    if median is not None:
                        result[ward_name][qlabel] = median

    return result


def get_all_quarters(data: Dict[str, Dict[str, Optional[int]]]) -> List[str]:
    """全四半期ラベルをソートして返す。"""
    quarters = set()
    for ward_data in data.values():
        quarters.update(ward_data.keys())
    return sorted(quarters)


def get_ward_color(ward_name: str) -> str:
    """区名からティア色を返す。"""
    for tier, wards in WARD_TIERS.items():
        if ward_name in wards:
            idx = wards.index(ward_name)
            colors = TIER_COLORS[tier]
            return colors[idx % len(colors)]
    return "rgb(107, 114, 128)"  # gray fallback


def get_ward_tier(ward_name: str) -> str:
    """区名からティアラベルを返す。"""
    for tier, wards in WARD_TIERS.items():
        if ward_name in wards:
            return tier
    return "Other"


def generate_html(data: Dict[str, Dict[str, Optional[int]]], quarters: List[str]) -> str:
    """Chart.js を使ったインタラクティブHTMLを生成。"""

    # 区をティア順にソート
    tier_order = list(WARD_TIERS.keys())
    def sort_key(ward_name):
        for i, (tier, wards) in enumerate(WARD_TIERS.items()):
            if ward_name in wards:
                return (i, wards.index(ward_name))
        return (99, 0)

    sorted_wards = sorted(data.keys(), key=sort_key)

    # データセットをJSON形式で構築
    datasets = []
    for ward_name in sorted_wards:
        ward_data = data[ward_name]
        color = get_ward_color(ward_name)
        tier = get_ward_tier(ward_name)
        values = []
        for q in quarters:
            val = ward_data.get(q)
            values.append(val if val else "null")

        dataset = {
            "label": ward_name,
            "data": values,
            "borderColor": color,
            "backgroundColor": color.replace("rgb", "rgba").replace(")", ", 0.1)"),
            "borderWidth": 2,
            "pointRadius": 3,
            "pointHoverRadius": 6,
            "tension": 0.3,
            "fill": False,
            "tier": tier,
        }
        datasets.append(dataset)

    # 四半期ラベルを見やすく整形
    quarter_labels = []
    for q in quarters:
        year = q[:4]
        qnum = q[-1]
        quarter_labels.append(f"{year}Q{qnum}")

    # 最新データの要約テーブル用
    latest_q = quarters[-1] if quarters else ""
    first_q = quarters[0] if quarters else ""

    summary_rows = []
    for ward_name in sorted_wards:
        ward_data = data[ward_name]
        latest_val = ward_data.get(latest_q)
        first_val = ward_data.get(first_q)
        change_pct = None
        if latest_val and first_val and first_val > 0:
            change_pct = round((latest_val - first_val) / first_val * 100, 1)
        tier = get_ward_tier(ward_name)
        color = get_ward_color(ward_name)
        summary_rows.append({
            "ward": ward_name,
            "tier": tier,
            "latest": latest_val,
            "first": first_val,
            "change_pct": change_pct,
            "color": color,
        })

    # datasets JSON（null 値の処理）
    datasets_json_parts = []
    for ds in datasets:
        vals = ds["data"]
        data_str = "[" + ", ".join(str(v) for v in vals) + "]"
        datasets_json_parts.append(f"""{{
          label: '{ds["label"]}',
          data: {data_str},
          borderColor: '{ds["borderColor"]}',
          backgroundColor: '{ds["backgroundColor"]}',
          borderWidth: 2,
          pointRadius: 3,
          pointHoverRadius: 6,
          tension: 0.3,
          fill: false,
          tier: '{ds["tier"]}',
          hidden: false
        }}""")

    datasets_js = ",\n        ".join(datasets_json_parts)
    labels_js = json.dumps(quarter_labels, ensure_ascii=False)

    # サマリーテーブルHTML
    summary_html_rows = []
    for row in sorted(summary_rows, key=lambda r: -(r["change_pct"] or 0)):
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
        tier_label = row["tier"].split("_")[1] if "_" in row["tier"] else row["tier"]
        summary_html_rows.append(f"""
          <tr>
            <td><span class="color-dot" style="background:{row['color']}"></span>{row['ward']}</td>
            <td class="tier-cell">{tier_label}</td>
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
  <title>東京23区 中古マンション m²単価推移</title>
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
    tr:hover {{
      background: #f8fafc;
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
  <h1>東京23区 中古マンション m&sup2;単価推移</h1>
  <p class="subtitle">成約価格ベース &middot; 国土交通省 不動産情報ライブラリ &middot; {first_q}〜{latest_q}</p>

  <div class="stats-row" id="statsRow"></div>

  <div class="chart-container">
    <div class="filter-bar">
      <span class="filter-label">表示:</span>
      <button class="filter-btn active" data-filter="all">全23区</button>
      <button class="filter-btn" data-filter="Tier1_都心">都心4区</button>
      <button class="filter-btn" data-filter="Tier2_準都心">準都心6区</button>
      <button class="filter-btn" data-filter="Tier3_城西・城南">城西・城南4区</button>
      <button class="filter-btn" data-filter="Tier4_城北・城東">城北・城東9区</button>
    </div>
    <div class="chart-wrapper">
      <canvas id="trendChart"></canvas>
    </div>
  </div>

  <div class="summary-section">
    <h2>区別サマリー（変動率順）</h2>
    <table>
      <thead>
        <tr>
          <th>区</th>
          <th>ティア</th>
          <th class="number">{first_q}</th>
          <th class="number">{latest_q}</th>
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
    const latest = allDatasets.map(d => ({{ name: d.label, val: d.data[d.data.length - 1], tier: d.tier }})).filter(d => d.val);
    const avgAll = Math.round(latest.reduce((s, d) => s + d.val, 0) / latest.length);
    const maxWard = latest.reduce((a, b) => a.val > b.val ? a : b);
    const minWard = latest.reduce((a, b) => a.val < b.val ? a : b);

    // 全期間の平均変動率
    const firstVals = allDatasets.map(d => ({{ name: d.label, first: d.data.find(v => v !== null), last: d.data[d.data.length - 1] }})).filter(d => d.first && d.last);
    const avgChange = firstVals.length ? Math.round(firstVals.reduce((s, d) => s + (d.last - d.first) / d.first * 100, 0) / firstVals.length * 10) / 10 : 0;

    statsRow.innerHTML = `
      <div class="stat-card">
        <div class="stat-label">23区平均 m&sup2;単価</div>
        <div class="stat-value">&yen;${{avgAll.toLocaleString()}}</div>
        <div class="stat-sub">直近四半期</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">最高値</div>
        <div class="stat-value">&yen;${{maxWard.val.toLocaleString()}}</div>
        <div class="stat-sub">${{maxWard.name}}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">最安値</div>
        <div class="stat-value">&yen;${{minWard.val.toLocaleString()}}</div>
        <div class="stat-sub">${{minWard.name}}</div>
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
                return val ? `${{ctx.dataset.label}}: ¥${{val.toLocaleString()}}/m²` : '';
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

    // フィルタボタン
    document.querySelectorAll('.filter-btn').forEach(btn => {{
      btn.addEventListener('click', () => {{
        document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        const filter = btn.dataset.filter;
        chart.data.datasets.forEach(ds => {{
          if (filter === 'all') {{
            ds.hidden = false;
          }} else {{
            ds.hidden = ds.tier !== filter;
          }}
        }});
        chart.update();
      }});
    }});
  </script>
</body>
</html>"""
    return html


def main():
    print("=== 東京23区 m²単価推移チャート生成 ===", file=sys.stderr)

    # データ読み込み
    trends = load_trends_data()
    history = load_history_data()

    if not trends and not history:
        print("エラー: データファイルが見つかりません", file=sys.stderr)
        sys.exit(1)

    # データ統合
    merged = merge_data(trends, history)
    quarters = get_all_quarters(merged)

    print(f"区数: {len(merged)}", file=sys.stderr)
    print(f"期間: {quarters[0]} 〜 {quarters[-1]} ({len(quarters)} 四半期)", file=sys.stderr)

    # HTML生成
    html = generate_html(merged, quarters)

    os.makedirs(RESULTS_DIR, exist_ok=True)
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"出力: {OUTPUT_FILE}", file=sys.stderr)


if __name__ == "__main__":
    main()
