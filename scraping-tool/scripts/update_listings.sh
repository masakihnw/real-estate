#!/bin/bash
# 定期実行用スクリプト: 物件情報を取得し、Markdownレポートを生成
#
# パイプライン構成:
#   Phase 1:  スクレイピング（中古 & 新築を並列実行）
#   Phase 2a: 共有キャッシュ書き込み enricher（順次実行で競合回避）
#   Phase 2b: 読み取り専用 enricher（中古/新築/成約実績の3トラック並列）
#   Phase 2c: 共有マニフェスト書き込み（upload_floor_plans を順次実行）
#   Phase 3:  合流 → レポート生成 → 通知 → コミット

set -e

# スクリプト配置が scraping-tool/scripts/ である前提。作業ディレクトリは scraping-tool/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_DIR="results"
REPORT_DIR="${OUTPUT_DIR}/report"
mkdir -p "$REPORT_DIR"

DATE=$(TZ=Asia/Tokyo date +%Y%m%d_%H%M%S)
CURRENT="${OUTPUT_DIR}/current_${DATE}.json"
REPORT="${REPORT_DIR}/report.md"

CURRENT_SHINCHIKU="${OUTPUT_DIR}/current_shinchiku_${DATE}.json"

# ──────────────────────────── 所要時間計測 ────────────────────────────
TIMING_DIR="${OUTPUT_DIR}/.timing"
mkdir -p "$TIMING_DIR"
rm -f "$TIMING_DIR"/*.tsv
PIPELINE_START=$(date +%s)

record_timing() {
    local timing_file="$1"
    local step_name="$2"
    local start_time="$3"
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))
    echo "[TIMING] ${step_name}: ${minutes}m ${seconds}s" >&2
    printf "%s\t%d\n" "$step_name" "$elapsed" >> "$timing_file"
}

print_timing_summary() {
    local pipeline_end=$(date +%s)
    local pipeline_elapsed=$((pipeline_end - PIPELINE_START))
    local pipeline_min=$((pipeline_elapsed / 60))
    local pipeline_sec=$((pipeline_elapsed % 60))

    echo "" >&2
    echo "==========================================" >&2
    echo " 所要時間サマリー" >&2
    echo "==========================================" >&2
    printf "%-40s %10s\n" "ステップ" "所要時間" >&2
    echo "---------------------------------------------------" >&2

    for tsv_file in "$TIMING_DIR"/main.tsv "$TIMING_DIR"/phase2a.tsv "$TIMING_DIR"/track_a.tsv "$TIMING_DIR"/track_b.tsv "$TIMING_DIR"/track_c.tsv "$TIMING_DIR"/phase2c.tsv; do
        [ -f "$tsv_file" ] || continue
        local label=""
        case "$tsv_file" in
            *track_a*) label="  [Track A: 中古]" ;;
            *track_b*) label="  [Track B: 新築]" ;;
            *track_c*) label="  [Track C: 成約実績]" ;;
        esac
        [ -n "$label" ] && echo "$label" >&2
        local indent="  "
        [ -n "$label" ] && indent="    "
        while IFS=$'\t' read -r step_name elapsed; do
            local minutes=$((elapsed / 60))
            local seconds=$((elapsed % 60))
            printf "${indent}%-36s %4dm %02ds\n" "$step_name" "$minutes" "$seconds" >&2
        done < "$tsv_file"
    done

    echo "---------------------------------------------------" >&2
    printf "  %-38s %4dm %02ds\n" "TOTAL" "$pipeline_min" "$pipeline_sec" >&2
    echo "==========================================" >&2

    # ログファイルにも記録
    echo "" >> "$LOG_FILE"
    echo "=== 所要時間サマリー ===" >> "$LOG_FILE"
    for tsv_file in "$TIMING_DIR"/main.tsv "$TIMING_DIR"/phase2a.tsv "$TIMING_DIR"/track_a.tsv "$TIMING_DIR"/track_b.tsv "$TIMING_DIR"/track_c.tsv "$TIMING_DIR"/phase2c.tsv; do
        [ -f "$tsv_file" ] || continue
        while IFS=$'\t' read -r step_name elapsed; do
            local minutes=$((elapsed / 60))
            local seconds=$((elapsed % 60))
            printf "[TIMING] %s: %dm %ds\n" "$step_name" "$minutes" "$seconds" >> "$LOG_FILE"
        done < "$tsv_file"
    done
    printf "[TIMING] TOTAL: %dm %ds\n" "$pipeline_min" "$pipeline_sec" >> "$LOG_FILE"
}

# ──────────────────────────── プロセス管理 ────────────────────────────
BG_PIDS=""
register_bg_pid() { BG_PIDS="$BG_PIDS $1"; }
kill_bg_pids() {
    for pid in $BG_PIDS; do
        kill "$pid" 2>/dev/null && echo "バックグラウンドプロセス $pid を停止" >&2 || true
    done
    BG_PIDS=""
}

# ──────────────────────────── ログ設定 ────────────────────────────
LOG_FILE="${OUTPUT_DIR}/scraping_log.txt"
exec 3>&2  # 元の stderr を fd3 に退避
exec 2> >(tee -a "$LOG_FILE" >&3)  # stderr を tee でファイルとコンソールに分岐

echo "=== スクレイピングログ ===" > "$LOG_FILE"
echo "実行日時: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')（JST）" >> "$LOG_FILE"
echo "==========================================" >> "$LOG_FILE"

# エラー時: バックグラウンドプロセス停止 → タイミングサマリー → ログアップロード
trap '
    echo "=== エラーにより中断 ===" >&2
    kill_bg_pids
    print_timing_summary 2>/dev/null || true
    echo "=== エラーにより中断 ===" >> "$LOG_FILE"
    python3 upload_scraping_log.py "$LOG_FILE" --status error 2>/dev/null || true
' ERR

echo "=== 物件情報取得開始 ===" >&2
echo "日時: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')（JST）" >&2

# ══════════════════════════════════════════════════════════════════
# Phase 1: スクレイピング（中古・新築を並列実行）
# ══════════════════════════════════════════════════════════════════
echo "--- Phase 1: スクレイピング（中古・新築並列実行） ---" >&2

_t_chuko=$(date +%s)
python3 main.py --source suumo --property-type chuko -o "$CURRENT" &
CHUKO_PID=$!
register_bg_pid $CHUKO_PID

_t_shinchiku=$(date +%s)
python3 main.py --source suumo --property-type shinchiku -o "$CURRENT_SHINCHIKU" &
SHINCHIKU_PID=$!
register_bg_pid $SHINCHIKU_PID

echo "[並列] 中古 (PID: $CHUKO_PID) + 新築 (PID: $SHINCHIKU_PID) スクレイピング実行中..." >&2

# 中古完了を待機（必須: set -e により失敗時は ERR trap → 新築も停止して exit）
wait $CHUKO_PID
record_timing "$TIMING_DIR/main.tsv" "scraping_chuko" "$_t_chuko"

# 新築完了を待機（失敗は許容して続行）
wait $SHINCHIKU_PID || echo "新築取得エラー（中古は続行）" >&2
record_timing "$TIMING_DIR/main.tsv" "scraping_shinchiku" "$_t_shinchiku"

BG_PIDS=""  # 両方完了したのでクリア

# 中古バリデーション
if [ ! -s "$CURRENT" ]; then
    echo "エラー: 中古データが取得できませんでした" >&2
    exit 1
fi

COUNT=$(python3 -c "import json; print(len(json.load(open('$CURRENT'))))")
if [ "$COUNT" -eq 0 ]; then
    echo "エラー: 中古データが 0 件です（フィルタ設定を確認してください）" >&2
    exit 1
fi
echo "中古取得件数: ${COUNT}件" >&2

SHINCHIKU_COUNT=0
if [ -s "$CURRENT_SHINCHIKU" ]; then
    SHINCHIKU_COUNT=$(python3 -c "import json; print(len(json.load(open('$CURRENT_SHINCHIKU'))))")
fi
echo "新築取得件数: ${SHINCHIKU_COUNT}件" >&2

# ─── 変更検出 ───
_t=$(date +%s)
HAS_CHANGES=false
if [ -f "${OUTPUT_DIR}/latest.json" ]; then
    if python3 check_changes.py "$CURRENT" "${OUTPUT_DIR}/latest.json"; then
        echo "中古: 変更あり" >&2
        HAS_CHANGES=true
    else
        echo "中古: 変更なし" >&2
    fi
else
    HAS_CHANGES=true  # 初回実行
fi

if [ -s "$CURRENT_SHINCHIKU" ] && [ -f "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
    if python3 check_changes.py "$CURRENT_SHINCHIKU" "${OUTPUT_DIR}/latest_shinchiku.json"; then
        echo "新築: 変更あり" >&2
        HAS_CHANGES=true
    else
        echo "新築: 変更なし" >&2
    fi
elif [ -s "$CURRENT_SHINCHIKU" ]; then
    HAS_CHANGES=true  # 新築初回
fi
record_timing "$TIMING_DIR/main.tsv" "change_detection" "$_t"

if [ "$HAS_CHANGES" = false ]; then
    echo "中古・新築ともに変更なし（レポート・通知をスキップ）" >&2
    rm -f "$CURRENT" "$CURRENT_SHINCHIKU"
    echo "ログを Firestore にアップロード中（変更なし）..." >&2
    print_timing_summary
    python3 upload_scraping_log.py "$LOG_FILE" --status success 2>&1 || echo "ログアップロード失敗" >&2
    exit 0
fi

# GitHub Actions 実行時のレポート・マップ URL
REPORT_URL_ARG=""
MAP_URL_ARG=""
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    REPORT_URL="https://github.com/${GITHUB_REPOSITORY}/blob/${GITHUB_REF_NAME}/scraping-tool/results/report/report.md"
    REPORT_URL_ARG="--report-url ${REPORT_URL}"
    MAP_URL="https://htmlpreview.github.io/?https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${GITHUB_REF_NAME}/scraping-tool/results/map_viewer.html"
    MAP_URL_ARG="--map-url ${MAP_URL}"
fi

# ─── latest.json / latest_shinchiku.json 保存 ───
cp "${OUTPUT_DIR}/latest.json" "${OUTPUT_DIR}/previous.json" 2>/dev/null || true
cp "$CURRENT" "${OUTPUT_DIR}/latest.json"
if [ -s "$CURRENT_SHINCHIKU" ]; then
    cp "${OUTPUT_DIR}/latest_shinchiku.json" "${OUTPUT_DIR}/previous_shinchiku.json" 2>/dev/null || true
    cp "$CURRENT_SHINCHIKU" "${OUTPUT_DIR}/latest_shinchiku.json"
    echo "新築: ${OUTPUT_DIR}/latest_shinchiku.json に保存" >&2
fi

# ─── is_new フラグ注入 ───
echo "is_new フラグを注入中..." >&2
python3 -c "
import json, sys
sys.path.insert(0, '.')
from report_utils import inject_is_new, load_json
from pathlib import Path

out = '${OUTPUT_DIR}'

cur = load_json(Path(f'{out}/latest.json'))
prev = load_json(Path(f'{out}/previous.json'), missing_ok=True, default=[])
inject_is_new(cur, prev or None)
with open(f'{out}/latest.json', 'w', encoding='utf-8') as f:
    json.dump(cur, f, ensure_ascii=False)

cur_s = load_json(Path(f'{out}/latest_shinchiku.json'), missing_ok=True, default=[])
prev_s = load_json(Path(f'{out}/previous_shinchiku.json'), missing_ok=True, default=[])
if cur_s:
    inject_is_new(cur_s, prev_s or None)
    with open(f'{out}/latest_shinchiku.json', 'w', encoding='utf-8') as f:
        json.dump(cur_s, f, ensure_ascii=False)

new_c = sum(1 for r in cur if r.get('is_new'))
new_s = sum(1 for r in cur_s if r.get('is_new'))
print(f'is_new 注入完了: 中古 {new_c}/{len(cur)}件, 新築 {new_s}/{len(cur_s)}件', file=sys.stderr)
" || echo "is_new 注入失敗（続行）" >&2

# ─── 価格変動・掲載日数・競合物件数注入 ───
echo "価格変動・掲載日数・競合物件数を注入中..." >&2
python3 -c "
import json, sys
sys.path.insert(0, '.')
from report_utils import inject_price_history, inject_first_seen_at, inject_competing_count, load_json
from pathlib import Path

out = '${OUTPUT_DIR}'

cur = load_json(Path(f'{out}/latest.json'))
prev = load_json(Path(f'{out}/previous.json'), missing_ok=True, default=[])
inject_price_history(cur, prev or None)
inject_first_seen_at(cur, prev or None)
inject_competing_count(cur)
with open(f'{out}/latest.json', 'w', encoding='utf-8') as f:
    json.dump(cur, f, ensure_ascii=False)

cur_s = load_json(Path(f'{out}/latest_shinchiku.json'), missing_ok=True, default=[])
prev_s = load_json(Path(f'{out}/previous_shinchiku.json'), missing_ok=True, default=[])
if cur_s:
    inject_price_history(cur_s, prev_s or None)
    inject_first_seen_at(cur_s, prev_s or None)
    inject_competing_count(cur_s)
    with open(f'{out}/latest_shinchiku.json', 'w', encoding='utf-8') as f:
        json.dump(cur_s, f, ensure_ascii=False)

print(f'価格変動・掲載日数・競合物件数 注入完了', file=sys.stderr)
" || echo "価格変動注入失敗（続行）" >&2

# ─── enrichment 前バックアップ ───
cp "${OUTPUT_DIR}/latest.json" "${OUTPUT_DIR}/latest.json.backup"
[ -s "${OUTPUT_DIR}/latest_shinchiku.json" ] && cp "${OUTPUT_DIR}/latest_shinchiku.json" "${OUTPUT_DIR}/latest_shinchiku.json.backup" || true

# ─── ブラウザフラグ検出 ───
BROWSER_FLAG=""
if python3 -c "
import sys
try:
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        path = p.chromium.executable_path
        import os
        if os.path.isfile(path):
            sys.exit(0)
        else:
            sys.exit(1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    BROWSER_FLAG="--browser"
    echo "playwright 検出（ブラウザバイナリ確認済み）: ブラウザ自動化を含めて実行" >&2
else
    echo "playwright 未検出またはブラウザバイナリなし: ブラウザ自動化スキップ" >&2
fi

# ─── 東京都地域危険度 GeoJSON 生成（初回のみ、Phase 2 前に実行して競合を回避） ───
RISK_GEOJSON_DIR="${OUTPUT_DIR}/risk_geojson"
if [ ! -f "${RISK_GEOJSON_DIR}/building_collapse_risk.geojson" ]; then
    echo "東京都地域危険度 GeoJSON を生成中（初回のみ）..." >&2
    _t=$(date +%s)
    python3 scripts/convert_risk_geojson.py 2>&1 || echo "GeoJSON 変換失敗（geopandas 未インストール？ GSI タイルのみでハザード判定を続行）" >&2
    record_timing "$TIMING_DIR/main.tsv" "risk_geojson" "$_t"
else
    echo "東京都地域危険度 GeoJSON: 生成済み（スキップ）" >&2
fi

HAS_SHINCHIKU=false
[ -s "${OUTPUT_DIR}/latest_shinchiku.json" ] && HAS_SHINCHIKU=true

TIMING_2A="$TIMING_DIR/phase2a.tsv"

# ══════════════════════════════════════════════════════════════════
# Phase 2a: 共有キャッシュ書き込み enricher（順次実行で競合回避）
#   - sumai_surfin_cache.json, geocode_cache.json, station_cache.json 等を
#     安全に読み書きするため、このフェーズは全て順次実行する
# ══════════════════════════════════════════════════════════════════
echo "" >&2
echo "--- Phase 2a: 共有キャッシュ enricher（順次実行） ---" >&2
_t_phase2a=$(date +%s)

# 2a-1. build_units_cache (中古) と shinchiku_detail_enricher (新築) は
#       別々のキャッシュ（html_cache/ vs shinchiku_html_cache/）を使うため並列可能
_t=$(date +%s)
echo "build_units_cache (中古) + shinchiku_detail_enricher (新築) 並列実行中..." >&2

python3 scripts/build_units_cache.py "${OUTPUT_DIR}/latest.json" &
BU_PID=$!
register_bg_pid $BU_PID

SD_PID=""
if [ "$HAS_SHINCHIKU" = true ]; then
    python3 shinchiku_detail_enricher.py --input "${OUTPUT_DIR}/latest_shinchiku.json" --output "${OUTPUT_DIR}/latest_shinchiku.json" &
    SD_PID=$!
    register_bg_pid $SD_PID
fi

wait $BU_PID || echo "build_units_cache に失敗しました（続行）" >&2
record_timing "$TIMING_2A" "build_units_cache" "$_t"

if [ -n "$SD_PID" ]; then
    wait $SD_PID || echo "shinchiku_detail_enricher に失敗しました（続行）" >&2
    record_timing "$TIMING_2A" "shinchiku_detail_enricher" "$_t"
fi
BG_PIDS=""

# 2a-2. merge_detail_cache (中古: build_units_cache の結果をマージ)
_t=$(date +%s)
python3 scripts/merge_detail_cache.py "${OUTPUT_DIR}/latest.json" || echo "詳細キャッシュのマージに失敗しました（続行）" >&2
record_timing "$TIMING_2A" "merge_detail_cache" "$_t"

# 2a-3. 住まいサーフィン enrichment（共有キャッシュ sumai_surfin_cache.json のため順次実行）
echo "住まいサーフィン enrichment (中古) 実行中..." >&2
_t=$(date +%s)
python3 sumai_surfin_enricher.py --input "${OUTPUT_DIR}/latest.json" --output "${OUTPUT_DIR}/latest.json" --property-type chuko $BROWSER_FLAG || echo "住まいサーフィン enrichment (中古) 失敗（続行）" >&2
record_timing "$TIMING_2A" "sumai_surfin_chuko" "$_t"

if [ "$HAS_SHINCHIKU" = true ]; then
    echo "住まいサーフィン enrichment (新築) 実行中..." >&2
    _t=$(date +%s)
    python3 sumai_surfin_enricher.py --input "${OUTPUT_DIR}/latest_shinchiku.json" --output "${OUTPUT_DIR}/latest_shinchiku.json" --property-type shinchiku $BROWSER_FLAG || echo "住まいサーフィン enrichment (新築) 失敗（続行）" >&2
    record_timing "$TIMING_2A" "sumai_surfin_shinchiku" "$_t"
fi

# 2a-4. ジオコーディングパイプライン（共有キャッシュ geocode_cache.json 等のため順次実行）
#       ss_address 確定後に実行するため、build_map_viewer の精度が向上
echo "物件マップを生成中（ss_address 活用、中古+新築）..." >&2
_t=$(date +%s)
SHINCHIKU_FLAG=""
if [ "$HAS_SHINCHIKU" = true ]; then
    SHINCHIKU_FLAG="--shinchiku ${OUTPUT_DIR}/latest_shinchiku.json"
fi
python3 scripts/build_map_viewer.py "${OUTPUT_DIR}/latest.json" $SHINCHIKU_FLAG || echo "地図の生成に失敗しました（続行）" >&2
record_timing "$TIMING_2A" "build_map_viewer" "$_t"

echo "ジオコーディングを埋め込み中..." >&2
_t=$(date +%s)
python3 scripts/embed_geocode.py "${OUTPUT_DIR}/latest.json" || echo "embed_geocode (中古) に失敗しました（続行）" >&2
if [ "$HAS_SHINCHIKU" = true ]; then
    python3 scripts/embed_geocode.py "${OUTPUT_DIR}/latest_shinchiku.json" || echo "embed_geocode (新築) に失敗しました（続行）" >&2
fi
record_timing "$TIMING_2A" "embed_geocode" "$_t"

echo "ジオコーディングキャッシュを検証・クリーンアップ中..." >&2
_t=$(date +%s)
python3 scripts/geocode.py || true
record_timing "$TIMING_2A" "geocode_cache_cleanup" "$_t"

echo "座標の相互検証 + 修正試行中..." >&2
_t=$(date +%s)
python3 scripts/geocode_cross_validator.py "${OUTPUT_DIR}/latest.json" --fix || echo "⚠ 座標の相互検証（中古）で問題が検出されました" >&2
if [ "$HAS_SHINCHIKU" = true ]; then
    python3 scripts/geocode_cross_validator.py "${OUTPUT_DIR}/latest_shinchiku.json" --fix || echo "⚠ 座標の相互検証（新築）で問題が検出されました" >&2
fi
record_timing "$TIMING_2A" "geocode_cross_validator" "$_t"

record_timing "$TIMING_DIR/main.tsv" "phase2a_total" "$_t_phase2a"

# ══════════════════════════════════════════════════════════════════
# Phase 2b: 読み取り専用 enricher（3トラック並列実行）
#   - 共有キャッシュへの書き込みなし（geocode_cache 等は読み取りのみ）
#   - Track A: 中古（latest.json）
#   - Track B: 新築（latest_shinchiku.json）
#   - Track C: 成約実績フィード（完全独立）
# ══════════════════════════════════════════════════════════════════
echo "" >&2
echo "--- Phase 2b: 読み取り専用 enricher（3トラック並列実行） ---" >&2

TRACK_A_LOG="${OUTPUT_DIR}/.track_a.log"
TRACK_B_LOG="${OUTPUT_DIR}/.track_b.log"
TRACK_C_LOG="${OUTPUT_DIR}/.track_c.log"
> "$TRACK_A_LOG"
> "$TRACK_B_LOG"
> "$TRACK_C_LOG"

_t_phase2b=$(date +%s)

# ─── Track A: 中古（共有キャッシュ読み取りのみの enricher） ───
(
    set +e
    TIMING_FILE="$TIMING_DIR/track_a.tsv"

    echo "=== Track A: 中古 enrichment 開始 ===" >&2

    echo "ハザード enrichment (中古) 実行中..." >&2
    _t=$(date +%s)
    python3 hazard_enricher.py --input "${OUTPUT_DIR}/latest.json" --output "${OUTPUT_DIR}/latest.json" || echo "ハザード enrichment (中古) 失敗（続行）" >&2
    record_timing "$TIMING_FILE" "hazard_chuko" "$_t"

    echo "間取り図画像 enrichment (中古) 実行中..." >&2
    _t=$(date +%s)
    python3 floor_plan_enricher.py --input "${OUTPUT_DIR}/latest.json" --output "${OUTPUT_DIR}/latest.json" || echo "間取り図画像 enrichment (中古) 失敗（続行）" >&2
    record_timing "$TIMING_FILE" "floor_plan_chuko" "$_t"

    echo "通勤時間 enrichment (中古) 実行中..." >&2
    _t=$(date +%s)
    python3 commute_enricher.py --input "${OUTPUT_DIR}/latest.json" --output "${OUTPUT_DIR}/latest.json" || echo "通勤時間 enrichment (中古) 失敗（続行）" >&2
    record_timing "$TIMING_FILE" "commute_chuko" "$_t"

    if [ -f "data/reinfolib_prices.json" ]; then
        echo "不動産情報ライブラリ enrichment (中古) 実行中..." >&2
        _t=$(date +%s)
        python3 reinfolib_enricher.py --input "${OUTPUT_DIR}/latest.json" --output "${OUTPUT_DIR}/latest.json" || echo "不動産情報ライブラリ enrichment (中古) 失敗（続行）" >&2
        record_timing "$TIMING_FILE" "reinfolib_chuko" "$_t"
    fi

    if [ -f "data/estat_population.json" ]; then
        echo "e-Stat 人口動態 enrichment (中古) 実行中..." >&2
        _t=$(date +%s)
        python3 estat_enricher.py --input "${OUTPUT_DIR}/latest.json" --output "${OUTPUT_DIR}/latest.json" || echo "e-Stat 人口動態 enrichment (中古) 失敗（続行）" >&2
        record_timing "$TIMING_FILE" "estat_chuko" "$_t"
    fi

    echo "=== Track A: 中古 enrichment 完了 ===" >&2
) 2>"$TRACK_A_LOG" &
TRACK_A_PID=$!
register_bg_pid $TRACK_A_PID

# ─── Track B: 新築（共有キャッシュ読み取りのみの enricher） ───
TRACK_B_PID=""
if [ "$HAS_SHINCHIKU" = true ]; then
(
    set +e
    TIMING_FILE="$TIMING_DIR/track_b.tsv"

    echo "=== Track B: 新築 enrichment 開始 ===" >&2

    echo "ハザード enrichment (新築) 実行中..." >&2
    _t=$(date +%s)
    python3 hazard_enricher.py --input "${OUTPUT_DIR}/latest_shinchiku.json" --output "${OUTPUT_DIR}/latest_shinchiku.json" || echo "ハザード enrichment (新築) 失敗（続行）" >&2
    record_timing "$TIMING_FILE" "hazard_shinchiku" "$_t"

    echo "間取り図画像 enrichment (新築) 実行中..." >&2
    _t=$(date +%s)
    python3 floor_plan_enricher.py --input "${OUTPUT_DIR}/latest_shinchiku.json" --output "${OUTPUT_DIR}/latest_shinchiku.json" || echo "間取り図画像 enrichment (新築) 失敗（続行）" >&2
    record_timing "$TIMING_FILE" "floor_plan_shinchiku" "$_t"

    echo "通勤時間 enrichment (新築) 実行中..." >&2
    _t=$(date +%s)
    python3 commute_enricher.py --input "${OUTPUT_DIR}/latest_shinchiku.json" --output "${OUTPUT_DIR}/latest_shinchiku.json" || echo "通勤時間 enrichment (新築) 失敗（続行）" >&2
    record_timing "$TIMING_FILE" "commute_shinchiku" "$_t"

    if [ -f "data/reinfolib_prices.json" ]; then
        echo "不動産情報ライブラリ enrichment (新築) 実行中..." >&2
        _t=$(date +%s)
        python3 reinfolib_enricher.py --input "${OUTPUT_DIR}/latest_shinchiku.json" --output "${OUTPUT_DIR}/latest_shinchiku.json" || echo "不動産情報ライブラリ enrichment (新築) 失敗（続行）" >&2
        record_timing "$TIMING_FILE" "reinfolib_shinchiku" "$_t"
    fi

    if [ -f "data/estat_population.json" ]; then
        echo "e-Stat 人口動態 enrichment (新築) 実行中..." >&2
        _t=$(date +%s)
        python3 estat_enricher.py --input "${OUTPUT_DIR}/latest_shinchiku.json" --output "${OUTPUT_DIR}/latest_shinchiku.json" || echo "e-Stat 人口動態 enrichment (新築) 失敗（続行）" >&2
        record_timing "$TIMING_FILE" "estat_shinchiku" "$_t"
    fi

    echo "=== Track B: 新築 enrichment 完了 ===" >&2
) 2>"$TRACK_B_LOG" &
TRACK_B_PID=$!
register_bg_pid $TRACK_B_PID
else
    echo "新築データなし: Track B スキップ" >&2
fi

# ─── Track C: 成約実績フィード（完全独立） ───
TRACK_C_PID=""
if [ -n "${REINFOLIB_API_KEY:-}" ]; then
(
    set +e
    TIMING_FILE="$TIMING_DIR/track_c.tsv"

    echo "=== Track C: 成約実績フィード構築開始 ===" >&2

    _t=$(date +%s)
    python3 build_transaction_feed.py --quarters 20 --output "${OUTPUT_DIR}/transactions.json" || echo "成約実績フィード構築失敗（続行）" >&2
    record_timing "$TIMING_FILE" "build_transaction_feed" "$_t"

    echo "=== Track C: 成約実績フィード構築完了 ===" >&2
) 2>"$TRACK_C_LOG" &
TRACK_C_PID=$!
register_bg_pid $TRACK_C_PID
else
    echo "成約実績フィード: REINFOLIB_API_KEY 未設定のためスキップ" >&2
fi

# ─── 全トラック完了待機 ───
echo "全トラック完了を待機中..." >&2
TRACK_A_EXIT=0
TRACK_B_EXIT=0
TRACK_C_EXIT=0

wait $TRACK_A_PID || TRACK_A_EXIT=$?
[ -n "$TRACK_B_PID" ] && { wait $TRACK_B_PID || TRACK_B_EXIT=$?; }
[ -n "$TRACK_C_PID" ] && { wait $TRACK_C_PID || TRACK_C_EXIT=$?; }

BG_PIDS=""
record_timing "$TIMING_DIR/main.tsv" "phase2b_parallel_total" "$_t_phase2b"

# トラック別ログをメインの stderr に出力（tee 経由で LOG_FILE にも反映）
echo "" >&2
echo "--- Track A ログ ---" >&2
cat "$TRACK_A_LOG" >&2
if [ -s "$TRACK_B_LOG" ]; then
    echo "" >&2
    echo "--- Track B ログ ---" >&2
    cat "$TRACK_B_LOG" >&2
fi
if [ -s "$TRACK_C_LOG" ]; then
    echo "" >&2
    echo "--- Track C ログ ---" >&2
    cat "$TRACK_C_LOG" >&2
fi

echo "" >&2
echo "--- トラック完了状況 ---" >&2
echo "Track A (中古): exit=$TRACK_A_EXIT" >&2
[ -n "$TRACK_B_PID" ] && echo "Track B (新築): exit=$TRACK_B_EXIT" >&2
[ -n "$TRACK_C_PID" ] && echo "Track C (成約実績): exit=$TRACK_C_EXIT" >&2

rm -f "$TRACK_A_LOG" "$TRACK_B_LOG" "$TRACK_C_LOG"

# ══════════════════════════════════════════════════════════════════
# Phase 2c: 共有マニフェスト書き込み（upload_floor_plans を順次実行）
#   - floor_plan_storage_manifest.json を安全に読み書きするため順次
# ══════════════════════════════════════════════════════════════════
if [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
    echo "" >&2
    echo "--- Phase 2c: Firebase Storage アップロード（順次実行） ---" >&2

    echo "間取り図を Firebase Storage にアップロード中（中古）..." >&2
    _t=$(date +%s)
    python3 upload_floor_plans.py --input "${OUTPUT_DIR}/latest.json" --output "${OUTPUT_DIR}/latest.json" || echo "間取り図 Storage アップロード (中古) 失敗（続行）" >&2
    record_timing "$TIMING_DIR/phase2c.tsv" "upload_floor_plans_chuko" "$_t"

    if [ "$HAS_SHINCHIKU" = true ]; then
        echo "間取り図を Firebase Storage にアップロード中（新築）..." >&2
        _t=$(date +%s)
        python3 upload_floor_plans.py --input "${OUTPUT_DIR}/latest_shinchiku.json" --output "${OUTPUT_DIR}/latest_shinchiku.json" || echo "間取り図 Storage アップロード (新築) 失敗（続行）" >&2
        record_timing "$TIMING_DIR/phase2c.tsv" "upload_floor_plans_shinchiku" "$_t"
    fi
else
    echo "間取り図 Storage アップロード: FIREBASE_SERVICE_ACCOUNT 未設定のためスキップ" >&2
fi

# ══════════════════════════════════════════════════════════════════
# Phase 3: 合流（バリデーション → レポート → 通知 → クリーンアップ）
# ══════════════════════════════════════════════════════════════════
echo "" >&2
echo "--- Phase 3: 合流 ---" >&2

# ─── JSON バリデーション ───
if ! python3 -c "import json; json.load(open('${OUTPUT_DIR}/latest.json'))" 2>/dev/null; then
    echo "⚠ latest.json が破損しているためバックアップから復元します" >&2
    cp "${OUTPUT_DIR}/latest.json.backup" "${OUTPUT_DIR}/latest.json"
fi
if [ -s "${OUTPUT_DIR}/latest_shinchiku.json" ] && ! python3 -c "import json; json.load(open('${OUTPUT_DIR}/latest_shinchiku.json'))" 2>/dev/null; then
    echo "⚠ latest_shinchiku.json が破損しているためバックアップから復元します" >&2
    cp "${OUTPUT_DIR}/latest_shinchiku.json.backup" "${OUTPUT_DIR}/latest_shinchiku.json" 2>/dev/null || true
fi
rm -f "${OUTPUT_DIR}/latest.json.backup" "${OUTPUT_DIR}/latest_shinchiku.json.backup"

# ─── データ品質検証 ───
echo "データ品質検証中..." >&2
python3 scripts/validate_data.py "${OUTPUT_DIR}/latest.json" \
    --previous "${OUTPUT_DIR}/previous.json" --label "中古" \
    || echo "⚠ データ品質検証で問題が検出されました" >&2
if [ "$HAS_SHINCHIKU" = true ] && [ -s "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
    python3 scripts/validate_data.py "${OUTPUT_DIR}/latest_shinchiku.json" \
        --previous "${OUTPUT_DIR}/previous_shinchiku.json" --label "新築" \
        || echo "⚠ データ品質検証（新築）で問題が検出されました" >&2
fi

# ─── 投資スコア・供給トレンド注入（enrichment 完了後） ───
echo "投資スコア注入中..." >&2
_t=$(date +%s)
python3 investment_enricher.py "${OUTPUT_DIR}/latest.json" \
    --transactions "${OUTPUT_DIR}/transactions.json" \
    || echo "投資スコア注入（中古）失敗（続行）" >&2
if [ -s "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
    python3 investment_enricher.py "${OUTPUT_DIR}/latest_shinchiku.json" \
        --transactions "${OUTPUT_DIR}/transactions.json" \
        || echo "投資スコア注入（新築）失敗（続行）" >&2
fi
record_timing "$TIMING_DIR/main.tsv" "investment_scoring" "$_t"

echo "供給トレンド生成中..." >&2
_t=$(date +%s)
SHINCHIKU_TREND_ARGS=""
if [ -s "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
    SHINCHIKU_TREND_ARGS="--current-shinchiku ${OUTPUT_DIR}/latest_shinchiku.json"
    if [ -f "${OUTPUT_DIR}/previous_shinchiku.json" ]; then
        SHINCHIKU_TREND_ARGS="${SHINCHIKU_TREND_ARGS} --previous-shinchiku ${OUTPUT_DIR}/previous_shinchiku.json"
    fi
fi
python3 build_supply_trends.py \
    --current "${OUTPUT_DIR}/latest.json" \
    --previous "${OUTPUT_DIR}/previous.json" \
    $SHINCHIKU_TREND_ARGS \
    --output "${OUTPUT_DIR}/supply_trends.json" \
    || echo "供給トレンド生成失敗（続行）" >&2
record_timing "$TIMING_DIR/main.tsv" "supply_trends" "$_t"

# ─── レポート生成 ───
echo "レポートを生成中（enrichment 全反映）..." >&2
_t=$(date +%s)
if [ -f "${OUTPUT_DIR}/previous.json" ]; then
    python3 generate_report.py "${OUTPUT_DIR}/latest.json" --compare "${OUTPUT_DIR}/previous.json" -o "$REPORT" $REPORT_URL_ARG $MAP_URL_ARG
else
    python3 generate_report.py "${OUTPUT_DIR}/latest.json" -o "$REPORT" $REPORT_URL_ARG $MAP_URL_ARG
fi
cp "$REPORT" "${OUTPUT_DIR}/report_${DATE}.md"
record_timing "$TIMING_DIR/main.tsv" "report_generation" "$_t"

# ─── プッシュ通知 ───
if [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
    echo "プッシュ通知送信中..." >&2
    NEW_CHUKO=$(python3 -c "
import json
print(sum(1 for r in json.load(open('${OUTPUT_DIR}/latest.json')) if r.get('is_new')))
" 2>/dev/null || echo "0")
    NEW_SHINCHIKU=0
    if [ -f "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
        NEW_SHINCHIKU=$(python3 -c "
import json
print(sum(1 for r in json.load(open('${OUTPUT_DIR}/latest_shinchiku.json')) if r.get('is_new')))
" 2>/dev/null || echo "0")
    fi
    python3 scripts/send_push.py --new-count "$NEW_CHUKO" --shinchiku-count "$NEW_SHINCHIKU" || echo "プッシュ通知送信失敗（続行）" >&2
else
    echo "プッシュ通知: FIREBASE_SERVICE_ACCOUNT 未設定のためスキップ" >&2
fi

# ─── クリーンアップ ───
rm -f "$CURRENT" "$CURRENT_SHINCHIKU"
for f in "${OUTPUT_DIR}"/current_*.json; do
    [ -f "$f" ] || continue
    rm -f "$f" 2>/dev/null || true
done

OLD_REPORT_DIR="${REPORT_DIR}/old"
mkdir -p "$OLD_REPORT_DIR"
touch "${OLD_REPORT_DIR}/.gitkeep"
for f in "${OUTPUT_DIR}"/report_*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "report_${DATE}.md" ] && continue
    mv "$f" "${OLD_REPORT_DIR}/" 2>/dev/null || true
done
for f in "${REPORT_DIR}"/report_*.md; do
    [ -f "$f" ] || continue
    mv "$f" "${OLD_REPORT_DIR}/" 2>/dev/null || true
done

echo "=== 完了 ===" >&2
echo "レポート: $REPORT" >&2
echo "最新（中古）: ${OUTPUT_DIR}/latest.json" >&2
echo "最新（新築）: ${OUTPUT_DIR}/latest_shinchiku.json" >&2
echo "成約実績: ${OUTPUT_DIR}/transactions.json" >&2

# ─── 所要時間サマリー ───
print_timing_summary

# タイミングディレクトリをクリーンアップ
rm -rf "$TIMING_DIR"

# ─── キャッシュクリーンアップ ───
echo "キャッシュクリーンアップ中..." >&2
python3 scripts/cache_manager.py --stats --cleanup || echo "⚠ キャッシュクリーンアップ失敗（続行）" >&2

# ─── ログを Firestore にアップロード ───
echo "ログを Firestore にアップロード中..." >&2
python3 upload_scraping_log.py "$LOG_FILE" --status success 2>&1 || echo "ログアップロード失敗（続行）" >&2

# ─── Git操作（オプション: --no-git でスキップ可能） ───
if [ "$1" != "--no-git" ]; then
    REPO_ROOT="$SCRIPT_DIR"
    while [ ! -d "$REPO_ROOT/.git" ] && [ "$REPO_ROOT" != "/" ]; do
        REPO_ROOT=$(dirname "$REPO_ROOT")
    done
    
    if [ -d "$REPO_ROOT/.git" ]; then
        echo "=== Git操作開始 ===" >&2
        cd "$REPO_ROOT"
        REPORT_FILE="$SCRIPT_DIR/results/report/report.md"
        
        if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files -o --exclude-standard scraping-tool/results/)" ]; then
            echo "変更なし（スキップ）" >&2
        else
            if [ -f "$REPORT_FILE" ]; then
                SUMMARY=$(grep -A 3 "## 📊 変更サマリー" "$REPORT_FILE" 2>/dev/null | grep -E "🆕|🔄|❌" | head -3 | sed 's/^[[:space:]]*- //' | tr '\n' ' ' || echo "")
            fi
            
            COMMIT_MSG="Update listings: ${DATE}"
            if [ -n "$SUMMARY" ]; then
                COMMIT_MSG="${COMMIT_MSG}

${SUMMARY}"
            fi
            COMMIT_MSG="${COMMIT_MSG}

取得件数: ${COUNT}件
レポート: scraping-tool/${REPORT_DIR}/report.md"
            
            git add scraping-tool/results/ scraping-tool/data/floor_plan_storage_manifest.json scraping-tool/data/geocode_cache.json 2>/dev/null || true
            if git diff --cached --quiet; then
                echo "コミットする変更がありません" >&2
            else
                git commit -m "$COMMIT_MSG" || echo "コミット失敗（変更がない可能性）" >&2
                
                if git remote | grep -q .; then
                    echo "リモートにプッシュ中..." >&2
                    git push || echo "プッシュ失敗（手動で実行してください）" >&2
                else
                    echo "リモートが設定されていません（スキップ）" >&2
                fi
            fi
        fi
    else
        echo "Gitリポジトリが見つかりません（スキップ）" >&2
    fi
fi
