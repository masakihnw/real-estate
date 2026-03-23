#!/usr/bin/env python3
"""
通勤時間監査ツール - Google Maps 実測値との比較・修正

現在の commute_*.json の値と Google Maps の実測値を効率的に比較し、
ずれている値を修正するための HTML ツールを生成する。

使い方:
  python3 commute_audit.py                          # HTML監査ツールを生成
  python3 commute_audit.py --apply corrections.json  # 修正値をJSONに適用
"""

import argparse
import json
import sys
import urllib.parse
from datetime import datetime, timedelta, timezone
from pathlib import Path

from logger import get_logger
logger = get_logger(__name__)

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"

# ---------------------------------------------------------------------------
# オフィス定義
# ---------------------------------------------------------------------------
OFFICES = {
    "playground": {
        "name": "Playground株式会社",
        "short": "PG",
        "address": "千代田区一番町4-6 一番町中央ビル",
        "lat": 35.688449,
        "lon": 139.743415,
        "nearby_stations": [
            {"name": "半蔵門", "lines": "半蔵門線", "walk": 5},
            {"name": "九段下", "lines": "半蔵門線/東西線/都営新宿線", "walk": 7},
            {"name": "麹町", "lines": "有楽町線", "walk": 11},
            {"name": "市ヶ谷", "lines": "JR/有楽町線/南北線/都営新宿線", "walk": 15},
        ],
    },
    "m3career": {
        "name": "エムスリーキャリア株式会社",
        "short": "M3",
        "address": "港区虎ノ門4丁目1-28 虎ノ門タワーズオフィス",
        "lat": 35.666018,
        "lon": 139.743807,
        "nearby_stations": [
            {"name": "神谷町", "lines": "日比谷線", "walk": 7},
            {"name": "溜池山王", "lines": "銀座線/南北線", "walk": 12},
            {"name": "国会議事堂前", "lines": "丸ノ内線/千代田線", "walk": 16},
            {"name": "御成門", "lines": "都営三田線", "walk": 18},
        ],
    },
}


def next_weekday_830am_epoch() -> int:
    """次の平日 8:30 AM JST の UNIX エポック秒を返す（到着時刻として使用）。"""
    jst = timezone(timedelta(hours=9))
    now = datetime.now(jst)
    d = now.replace(hour=8, minute=30, second=0, microsecond=0)
    if d <= now:
        d += timedelta(days=1)
    while d.weekday() >= 5:  # 土日をスキップ
        d += timedelta(days=1)
    return int(d.timestamp())


def generate_gmaps_url(station_name: str, office: dict) -> str:
    """Google Maps の経路検索 URL を生成する（到着8:30指定）。"""
    origin = urllib.parse.quote(f"{station_name}駅")
    dest = f"{office['lat']},{office['lon']}"
    arrival_epoch = next_weekday_830am_epoch()
    # !3e3 = transit, !6e2 = arrive by, !8j = epoch
    return (
        f"https://www.google.com/maps/dir/{origin}/{dest}/"
        f"data=!4m6!4m5!2m3!6e2!7e2!8j{arrival_epoch}!3e3"
    )


# ---------------------------------------------------------------------------
# HTML 生成
# ---------------------------------------------------------------------------

def generate_html() -> str:
    """HTML 監査ツールを生成する。"""
    # JSON 読み込み
    data = {}
    for key in OFFICES:
        path = DATA_DIR / f"commute_{key}.json"
        if path.exists():
            with open(path, "r", encoding="utf-8") as f:
                data[key] = json.load(f)
        else:
            data[key] = {}

    # 全駅名の統合・ソート
    all_stations = sorted(set(
        list(data.get("playground", {}).keys()) +
        list(data.get("m3career", {}).keys())
    ))

    # 各駅のデータを構築
    stations_list = []
    for station in all_stations:
        entry = {"name": station}
        for key in OFFICES:
            entry[f"{key}_current"] = data[key].get(station)
            entry[f"{key}_url"] = generate_gmaps_url(station, OFFICES[key])
        stations_list.append(entry)

    # JS 用データ
    stations_json = json.dumps(stations_list, ensure_ascii=False, indent=2)
    offices_json = json.dumps(OFFICES, ensure_ascii=False, indent=2)

    return HTML_TEMPLATE.replace("__STATIONS_DATA__", stations_json).replace(
        "__OFFICES_DATA__", offices_json
    )


# ---------------------------------------------------------------------------
# HTML テンプレート
# ---------------------------------------------------------------------------

HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>通勤時間監査ツール</title>
<style>
:root {
  --bg: #0f1117;
  --surface: #1a1d27;
  --surface2: #242836;
  --border: #2e3348;
  --text: #e4e6f0;
  --text-dim: #8b8fa8;
  --accent: #6c8cff;
  --accent-dim: #4a5a8a;
  --green: #4ade80;
  --orange: #fb923c;
  --red: #f87171;
  --yellow: #fbbf24;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  background: var(--bg); color: var(--text);
  line-height: 1.6; padding: 20px; max-width: 1200px; margin: 0 auto;
}
h1 { font-size: 1.5rem; margin-bottom: 8px; }
.subtitle { color: var(--text-dim); font-size: 0.9rem; margin-bottom: 24px; }
.card {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: 12px; padding: 20px; margin-bottom: 16px;
}
.card h2 { font-size: 1.1rem; margin-bottom: 12px; }
.instructions ol { padding-left: 1.5em; color: var(--text-dim); font-size: 0.9rem; }
.instructions li { margin-bottom: 4px; }
.instructions strong { color: var(--yellow); }

/* Tabs */
.tabs { display: flex; gap: 8px; margin-bottom: 16px; }
.tab {
  padding: 8px 20px; border-radius: 8px; cursor: pointer;
  background: var(--surface2); border: 1px solid var(--border);
  color: var(--text-dim); font-size: 0.9rem; transition: all 0.2s;
}
.tab:hover { border-color: var(--accent-dim); }
.tab.active { background: var(--accent); color: #fff; border-color: var(--accent); }

/* Controls */
.controls {
  display: flex; gap: 12px; align-items: center; flex-wrap: wrap; margin-bottom: 16px;
}
.btn {
  padding: 8px 16px; border-radius: 8px; cursor: pointer;
  background: var(--surface2); border: 1px solid var(--border);
  color: var(--text); font-size: 0.85rem; transition: all 0.2s;
}
.btn:hover { border-color: var(--accent); background: var(--accent-dim); }
.btn-primary { background: var(--accent); border-color: var(--accent); color: #fff; }
.btn-primary:hover { background: #5a7aee; }
.btn-export { background: #16a34a; border-color: #16a34a; color: #fff; }
.btn-export:hover { background: #15803d; }

.progress-bar {
  flex: 1; min-width: 200px; height: 8px; background: var(--surface2);
  border-radius: 4px; overflow: hidden;
}
.progress-fill {
  height: 100%; background: var(--accent); border-radius: 4px;
  transition: width 0.3s;
}
.progress-text { font-size: 0.85rem; color: var(--text-dim); min-width: 80px; text-align: right; }

/* Filter */
.filter-group { display: flex; gap: 6px; }
.filter-btn {
  padding: 4px 12px; border-radius: 6px; cursor: pointer;
  background: transparent; border: 1px solid var(--border);
  color: var(--text-dim); font-size: 0.8rem; transition: all 0.2s;
}
.filter-btn.active { background: var(--accent-dim); border-color: var(--accent); color: var(--text); }

/* Nearby stations info */
.nearby-info {
  display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 16px;
  padding: 12px; background: var(--surface2); border-radius: 8px;
}
.nearby-chip {
  display: inline-flex; align-items: center; gap: 4px;
  padding: 4px 10px; border-radius: 6px; font-size: 0.8rem;
  background: var(--bg); border: 1px solid var(--border);
}
.nearby-chip .walk { color: var(--accent); font-weight: 600; }
.nearby-chip .lines { color: var(--text-dim); font-size: 0.75rem; }

/* Table */
table {
  width: 100%; border-collapse: collapse; font-size: 0.9rem;
}
thead th {
  background: var(--surface2); padding: 10px 12px; text-align: left;
  font-weight: 600; font-size: 0.8rem; color: var(--text-dim);
  border-bottom: 2px solid var(--border); position: sticky; top: 0; z-index: 10;
}
tbody td {
  padding: 8px 12px; border-bottom: 1px solid var(--border);
  vertical-align: middle;
}
tbody tr:hover { background: var(--surface2); }
tbody tr.checked { opacity: 0.7; }
tbody tr.changed { background: rgba(251, 191, 60, 0.05); }
tbody tr.big-diff { background: rgba(248, 113, 113, 0.08); }

.station-name { font-weight: 600; white-space: nowrap; }
.current-val { text-align: center; font-family: 'SF Mono', monospace; }
.gmaps-link {
  color: var(--accent); text-decoration: none; font-size: 0.85rem;
  white-space: nowrap;
}
.gmaps-link:hover { text-decoration: underline; }

.input-cell { text-align: center; }
.time-input {
  width: 60px; padding: 6px 8px; text-align: center;
  background: var(--bg); border: 1px solid var(--border);
  border-radius: 6px; color: var(--text); font-size: 0.9rem;
  font-family: 'SF Mono', monospace;
}
.time-input:focus { border-color: var(--accent); outline: none; }
.time-input.changed { border-color: var(--yellow); background: rgba(251, 191, 60, 0.1); }

.diff-cell {
  text-align: center; font-family: 'SF Mono', monospace;
  font-weight: 600; font-size: 0.85rem;
}
.diff-positive { color: var(--red); }
.diff-negative { color: var(--green); }
.diff-zero { color: var(--text-dim); }
.diff-large { color: var(--red); font-weight: 700; }

.status-cell { text-align: center; }
.status-icon { font-size: 1.1rem; }

/* Walk correction */
.walk-section {
  display: flex; gap: 16px; align-items: center; flex-wrap: wrap;
  padding: 12px; background: var(--surface2); border-radius: 8px; margin-bottom: 16px;
}
.walk-section label { font-size: 0.85rem; color: var(--text-dim); }
.walk-input {
  width: 60px; padding: 4px 8px; text-align: center;
  background: var(--bg); border: 1px solid var(--border);
  border-radius: 6px; color: var(--text); font-size: 0.9rem;
}
.walk-example { font-size: 0.8rem; color: var(--text-dim); }

/* Sort indicator */
th.sortable { cursor: pointer; user-select: none; }
th.sortable:hover { color: var(--accent); }
th .sort-arrow { margin-left: 4px; font-size: 0.7rem; }

/* Toast */
.toast {
  position: fixed; bottom: 20px; right: 20px;
  padding: 12px 20px; border-radius: 8px;
  background: var(--green); color: #000; font-weight: 600;
  font-size: 0.9rem; opacity: 0; transition: opacity 0.3s;
  z-index: 100;
}
.toast.show { opacity: 1; }
</style>
</head>
<body>

<h1>通勤時間監査ツール</h1>
<p class="subtitle">commute_*.json の値を Google Maps 実測値と比較・修正</p>

<div class="card instructions">
  <h2>使い方</h2>
  <ol>
    <li>オフィスタブを選択</li>
    <li>各駅の「Google Maps →」リンクをクリック（または「次の5駅を開く」ボタン）</li>
    <li>Google Maps で <strong>電車アイコン（🚃）</strong> を選択（到着 平日 8:30 が自動設定済み）</li>
    <li>表示された所要時間（分）を「実測値」欄に入力</li>
    <li>全て確認したら「JSONエクスポート」でダウンロード → data/ フォルダに配置</li>
  </ol>
  <p style="margin-top:8px; font-size:0.85rem; color:var(--text-dim);">
    ※ 進捗はブラウザの localStorage に自動保存されます。ページを閉じても続きから作業できます。
  </p>
</div>

<!-- Office tabs -->
<div class="tabs">
  <div class="tab active" data-office="playground" onclick="switchOffice('playground')">
    Playground（半蔵門）
  </div>
  <div class="tab" data-office="m3career" onclick="switchOffice('m3career')">
    M3Career（虎ノ門）
  </div>
</div>

<!-- Office nearby stations -->
<div id="nearby-container" class="nearby-info"></div>

<!-- Walk correction -->
<div class="walk-section">
  <label>徒歩補正係数:</label>
  <input type="number" id="walk-factor" class="walk-input" value="1.0" step="0.1" min="1.0" max="2.0"
         onchange="updateWalkFactor()">
  <span class="walk-example">
    例: 1.3 → 徒歩5分の物件は <span id="walk-example-val">5</span>分として計算
  </span>
</div>

<!-- Controls -->
<div class="controls">
  <button class="btn btn-primary" onclick="openNextBatch()">次の5駅を開く</button>
  <button class="btn" onclick="openNextBatch(10)">10駅を開く</button>
  <div class="filter-group">
    <button class="filter-btn active" data-filter="all" onclick="setFilter('all')">全て</button>
    <button class="filter-btn" data-filter="unchecked" onclick="setFilter('unchecked')">未確認</button>
    <button class="filter-btn" data-filter="changed" onclick="setFilter('changed')">変更あり</button>
    <button class="filter-btn" data-filter="big-diff" onclick="setFilter('big-diff')">差分大(5分+)</button>
  </div>
  <div class="progress-bar"><div class="progress-fill" id="progress-fill"></div></div>
  <span class="progress-text" id="progress-text">0/0</span>
</div>

<!-- Table -->
<table>
  <thead>
    <tr>
      <th style="width:40px">#</th>
      <th class="sortable" onclick="sortBy('name')">駅名 <span class="sort-arrow">▲▼</span></th>
      <th class="sortable" onclick="sortBy('current')" style="width:80px">現在値 <span class="sort-arrow">▲▼</span></th>
      <th style="width:120px">Google Maps</th>
      <th style="width:100px">実測値(分)</th>
      <th class="sortable" onclick="sortBy('diff')" style="width:80px">差分 <span class="sort-arrow">▲▼</span></th>
      <th style="width:60px">状態</th>
    </tr>
  </thead>
  <tbody id="station-tbody"></tbody>
</table>

<!-- Export -->
<div style="margin-top:24px; display:flex; gap:12px; flex-wrap:wrap;">
  <button class="btn btn-export" onclick="exportJSON()">JSONエクスポート（更新済みのみ）</button>
  <button class="btn btn-export" onclick="exportFullJSON()">JSONエクスポート（全駅）</button>
  <button class="btn" onclick="clearProgress()">進捗をリセット</button>
</div>

<div class="toast" id="toast"></div>

<script>
// ==========================
// Data
// ==========================
const STATIONS = __STATIONS_DATA__;
const OFFICES = __OFFICES_DATA__;

// State
let currentOffice = 'playground';
let currentFilter = 'all';
let sortField = 'name';
let sortAsc = true;
let walkFactor = 1.0;

// Progress stored per office: { stationName: { value: number|null, checked: bool } }
let progress = loadProgress();

function storageKey() {
  return 'commuteAudit_v1';
}

function loadProgress() {
  try {
    const raw = localStorage.getItem(storageKey());
    return raw ? JSON.parse(raw) : { playground: {}, m3career: {} };
  } catch { return { playground: {}, m3career: {} }; }
}

function saveProgress() {
  localStorage.setItem(storageKey(), JSON.stringify(progress));
}

// ==========================
// Rendering
// ==========================
function switchOffice(office) {
  currentOffice = office;
  document.querySelectorAll('.tab').forEach(t => {
    t.classList.toggle('active', t.dataset.office === office);
  });
  renderNearby();
  renderTable();
  updateProgress();
}

function renderNearby() {
  const office = OFFICES[currentOffice];
  const container = document.getElementById('nearby-container');
  const label = `<span style="font-size:0.85rem;color:var(--text-dim);margin-right:8px;">
    ${office.name} 最寄駅:</span>`;
  const chips = office.nearby_stations.map(s =>
    `<span class="nearby-chip">
      <strong>${s.name}</strong>
      <span class="walk">徒歩${s.walk}分</span>
      <span class="lines">${s.lines}</span>
    </span>`
  ).join('');
  container.innerHTML = label + chips;
}

function getStationData() {
  const officeKey = currentOffice;
  let list = STATIONS.map((s, idx) => {
    const currentVal = s[`${officeKey}_current`];
    const url = s[`${officeKey}_url`];
    const prog = (progress[officeKey] || {})[s.name] || {};
    const checked = !!prog.checked;
    const measuredVal = prog.value != null ? prog.value : null;
    const diff = (measuredVal != null && currentVal != null) ? measuredVal - currentVal : null;
    return {
      idx, name: s.name, currentVal, url, checked, measuredVal, diff,
    };
  });

  // Filter
  if (currentFilter === 'unchecked') list = list.filter(s => !s.checked);
  else if (currentFilter === 'changed') list = list.filter(s => s.diff != null && s.diff !== 0);
  else if (currentFilter === 'big-diff') list = list.filter(s => s.diff != null && Math.abs(s.diff) >= 5);

  // Sort
  list.sort((a, b) => {
    let va, vb;
    if (sortField === 'name') { va = a.name; vb = b.name; }
    else if (sortField === 'current') { va = a.currentVal ?? 999; vb = b.currentVal ?? 999; }
    else if (sortField === 'diff') { va = Math.abs(a.diff ?? 0); vb = Math.abs(b.diff ?? 0); }
    if (va < vb) return sortAsc ? -1 : 1;
    if (va > vb) return sortAsc ? 1 : -1;
    return 0;
  });

  return list;
}

function renderTable() {
  const list = getStationData();
  const tbody = document.getElementById('station-tbody');
  tbody.innerHTML = list.map((s, i) => {
    const rowClass = [];
    if (s.checked) rowClass.push('checked');
    if (s.diff != null && s.diff !== 0) rowClass.push('changed');
    if (s.diff != null && Math.abs(s.diff) >= 5) rowClass.push('big-diff');

    const diffHtml = s.diff != null
      ? `<span class="${s.diff > 0 ? (Math.abs(s.diff) >= 5 ? 'diff-large' : 'diff-positive') : s.diff < 0 ? 'diff-negative' : 'diff-zero'}">
          ${s.diff > 0 ? '+' : ''}${s.diff}分</span>`
      : '<span class="diff-zero">-</span>';

    const statusIcon = s.checked ? '✅' : '⬜';
    const inputClass = s.measuredVal != null && s.measuredVal !== s.currentVal ? 'time-input changed' : 'time-input';
    const inputVal = s.measuredVal != null ? s.measuredVal : '';

    return `<tr class="${rowClass.join(' ')}" data-station="${s.name}">
      <td style="color:var(--text-dim)">${i + 1}</td>
      <td class="station-name">${s.name}</td>
      <td class="current-val">${s.currentVal != null ? s.currentVal + '分' : '-'}</td>
      <td><a class="gmaps-link" href="${s.url}" target="_blank" rel="noopener"
             onclick="markOpened('${s.name}')">Google Maps →</a></td>
      <td class="input-cell">
        <input type="number" class="${inputClass}" value="${inputVal}" min="0" max="120"
               data-station="${s.name}"
               onchange="updateValue('${s.name}', this.value)"
               onkeydown="handleInputKey(event, '${s.name}')">
      </td>
      <td class="diff-cell">${diffHtml}</td>
      <td class="status-cell"><span class="status-icon">${statusIcon}</span></td>
    </tr>`;
  }).join('');
}

function updateProgress() {
  const officeData = progress[currentOffice] || {};
  const total = STATIONS.filter(s => s[`${currentOffice}_current`] != null).length;
  const checked = Object.values(officeData).filter(v => v.checked).length;
  const pct = total > 0 ? (checked / total * 100) : 0;
  document.getElementById('progress-fill').style.width = `${pct}%`;
  document.getElementById('progress-text').textContent = `${checked}/${total}`;
}

// ==========================
// Interactions
// ==========================
function markOpened(stationName) {
  // Just mark as opened (visual hint); actual "checked" happens on value entry
}

function updateValue(stationName, val) {
  if (!progress[currentOffice]) progress[currentOffice] = {};
  const numVal = val === '' ? null : parseInt(val, 10);
  progress[currentOffice][stationName] = {
    value: numVal,
    checked: numVal != null,
  };
  saveProgress();
  renderTable();
  updateProgress();
}

function handleInputKey(event, stationName) {
  if (event.key === 'Enter') {
    event.preventDefault();
    // Move to next visible input
    const inputs = Array.from(document.querySelectorAll('.time-input'));
    const currentIdx = inputs.findIndex(inp => inp.dataset.station === stationName);
    if (currentIdx >= 0 && currentIdx < inputs.length - 1) {
      inputs[currentIdx + 1].focus();
      inputs[currentIdx + 1].select();
    }
  }
}

function openNextBatch(count = 5) {
  const list = getStationData().filter(s => !s.checked);
  const batch = list.slice(0, count);
  batch.forEach(s => {
    window.open(s.url, '_blank');
  });
  if (batch.length > 0) {
    showToast(`${batch.length}駅のGoogle Mapsを開きました`);
    // Focus on the first unchecked input
    setTimeout(() => {
      const firstInput = document.querySelector(`input[data-station="${batch[0].name}"]`);
      if (firstInput) { firstInput.focus(); firstInput.select(); }
    }, 300);
  } else {
    showToast('未確認の駅はありません');
  }
}

function setFilter(filter) {
  currentFilter = filter;
  document.querySelectorAll('.filter-btn').forEach(b => {
    b.classList.toggle('active', b.dataset.filter === filter);
  });
  renderTable();
}

function sortBy(field) {
  if (sortField === field) sortAsc = !sortAsc;
  else { sortField = field; sortAsc = true; }
  renderTable();
}

function updateWalkFactor() {
  walkFactor = parseFloat(document.getElementById('walk-factor').value) || 1.0;
  const example = Math.round(5 * walkFactor);
  document.getElementById('walk-example-val').textContent = example;
}

// ==========================
// Export
// ==========================
function buildExportData(fullExport) {
  const result = {};
  for (const officeKey of ['playground', 'm3career']) {
    const current = {};
    STATIONS.forEach(s => {
      const val = s[`${officeKey}_current`];
      if (val != null) current[s.name] = val;
    });

    const officeProgress = progress[officeKey] || {};
    const updated = { ...current };
    let changeCount = 0;

    for (const [station, prog] of Object.entries(officeProgress)) {
      if (prog.value != null) {
        if (prog.value !== current[station]) changeCount++;
        updated[station] = prog.value;
      }
    }

    if (fullExport || changeCount > 0) {
      result[officeKey] = { data: updated, changes: changeCount };
    }
  }
  return result;
}

function exportJSON() {
  const exported = buildExportData(false);
  if (Object.keys(exported).length === 0) {
    showToast('変更がありません');
    return;
  }
  for (const [key, { data, changes }] of Object.entries(exported)) {
    downloadJSON(data, `commute_${key}.json`);
    showToast(`commute_${key}.json をエクスポート（${changes}件変更）`);
  }
}

function exportFullJSON() {
  const exported = buildExportData(true);
  for (const [key, { data, changes }] of Object.entries(exported)) {
    downloadJSON(data, `commute_${key}.json`);
  }
  showToast('全オフィスのJSONをエクスポートしました');
}

function downloadJSON(data, filename) {
  // Sort by value for readability
  const sorted = Object.fromEntries(
    Object.entries(data).sort((a, b) => a[1] - b[1])
  );
  const blob = new Blob(
    [JSON.stringify(sorted, null, 2) + '\n'],
    { type: 'application/json' }
  );
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = filename; a.click();
  URL.revokeObjectURL(url);
}

function clearProgress() {
  if (confirm('全ての進捗をリセットしますか？')) {
    progress = { playground: {}, m3career: {} };
    saveProgress();
    renderTable();
    updateProgress();
    showToast('進捗をリセットしました');
  }
}

// ==========================
// Toast
// ==========================
function showToast(msg) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.add('show');
  setTimeout(() => el.classList.remove('show'), 3000);
}

// ==========================
// Init
// ==========================
renderNearby();
renderTable();
updateProgress();
updateWalkFactor();
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Apply corrections
# ---------------------------------------------------------------------------

def apply_corrections(corrections_path: str) -> None:
    """エクスポートされた修正 JSON を data/ に適用する。"""
    path = Path(corrections_path)
    if not path.exists():
        logger.info(f"❌ ファイルが見つかりません: {path}")
        sys.exit(1)

    with open(path, "r", encoding="utf-8") as f:
        corrections = json.load(f)

    # ファイル名から office key を推定
    key = None
    for k in OFFICES:
        if k in path.stem:
            key = k
            break

    if key is None:
        logger.info(f"❌ ファイル名から通勤先を特定できません: {path.name}")
        logger.info("   ファイル名に 'playground' または 'm3career' を含めてください。")
        sys.exit(1)

    target = DATA_DIR / f"commute_{key}.json"

    # 既存データ読み込み
    existing = {}
    if target.exists():
        with open(target, "r", encoding="utf-8") as f:
            existing = json.load(f)

    # 差分表示
    changes = 0
    additions = 0
    for station, new_val in corrections.items():
        old_val = existing.get(station)
        if old_val is None:
            print(f"  + {station}: {new_val}分 (新規)")
            additions += 1
        elif old_val != new_val:
            diff = new_val - old_val
            print(f"  Δ {station}: {old_val}分 → {new_val}分 ({'+' if diff > 0 else ''}{diff})")
            changes += 1

    if changes == 0 and additions == 0:
        print("変更なし。")
        return

    # 適用
    existing.update(corrections)

    # ソートして保存
    sorted_data = dict(sorted(existing.items(), key=lambda x: x[1]))
    with open(target, "w", encoding="utf-8") as f:
        json.dump(sorted_data, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"\n✅ {target.name} を更新しました: {changes}件変更, {additions}件追加")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="通勤時間監査ツール")
    ap.add_argument("--apply", metavar="FILE", help="修正JSONを data/ に適用")
    args = ap.parse_args()

    if args.apply:
        apply_corrections(args.apply)
    else:
        html = generate_html()
        output = ROOT / "commute_audit.html"
        with open(output, "w", encoding="utf-8") as f:
            f.write(html)

        total = len(STATIONS) if 'STATIONS' in dir() else '?'
        # Count stations
        pg_path = DATA_DIR / "commute_playground.json"
        m3_path = DATA_DIR / "commute_m3career.json"
        pg_count = len(json.load(open(pg_path))) if pg_path.exists() else 0
        m3_count = len(json.load(open(m3_path))) if m3_path.exists() else 0
        all_stations = set()
        if pg_path.exists():
            all_stations.update(json.load(open(pg_path)).keys())
        if m3_path.exists():
            all_stations.update(json.load(open(m3_path)).keys())

        print(f"✅ HTML監査ツールを生成しました: {output}")
        print(f"   全 {len(all_stations)} 駅（PG: {pg_count}, M3: {m3_count}）")
        print(f"   検証項目数: {pg_count + m3_count} 件")
        print(f"\n   ブラウザで開いてください:")
        print(f"   open \"{output}\"")


if __name__ == "__main__":
    main()
