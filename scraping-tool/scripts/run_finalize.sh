#!/bin/bash
# WF2 finalize ジョブ用スクリプト
# 全 enrich ジョブの成果物を結合し、レポート生成・通知・コミットを行う。
# 一部ジョブが失敗しても利用可能なデータで最善の結果を出力する。
#
# 引数:
#   --is-slack-time true|false  Slack 通知を送信するかどうか
#   --date YYYYMMDD_HHMMSS      実行日時ラベル

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# ──────────────────────────── 引数パース ────────────────────────────

IS_SLACK_TIME=false
DATE=$(TZ=Asia/Tokyo date +%Y%m%d_%H%M%S)

while [[ $# -gt 0 ]]; do
    case $1 in
        --is-slack-time) IS_SLACK_TIME="$2"; shift 2 ;;
        --date) DATE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

OUTPUT_DIR="results"
REPORT_DIR="${OUTPUT_DIR}/report"
mkdir -p "$REPORT_DIR"

REPORT="${REPORT_DIR}/report.md"

echo "=== Finalize ===" >&2
echo "日時: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')（JST）" >&2

# ──────────────────────────── キャッシュマージ ────────────────────────────

echo "--- キャッシュマージ ---" >&2

# 各ジョブが更新した可能性のあるキャッシュをマージ
# enriched-chuko/, enriched-shinchiku/ ディレクトリから取得
for cache_file in geocode_cache.json sumai_surfin_cache.json floor_plan_storage_manifest.json station_cache.json reverse_geocode_cache.json; do
    UPDATES=""
    for job_dir in enriched-chuko enriched-shinchiku; do
        if [ -f "${job_dir}/data/${cache_file}" ]; then
            UPDATES="${UPDATES} ${job_dir}/data/${cache_file}"
        fi
    done

    if [ -n "$UPDATES" ]; then
        python3 scripts/merge_caches.py \
            --base "data/${cache_file}" \
            --updates $UPDATES \
            --output "data/${cache_file}" || echo "キャッシュマージ失敗: ${cache_file}（続行）" >&2
    fi
done

# ──────────────────────────── 成果物の配置 ────────────────────────────

echo "--- 成果物配置 ---" >&2

# enriched-chuko の latest.json を配置
# upload-artifact@v4 は共通祖先 (scraping-tool/) を除去するため、
# ダウンロード先には results/latest.json として展開される
CHUKO_ENRICHED=""
for candidate in "enriched-chuko/latest.json" "enriched-chuko/results/latest.json"; do
    if [ -f "$candidate" ]; then
        CHUKO_ENRICHED="$candidate"
        break
    fi
done
if [ -n "$CHUKO_ENRICHED" ]; then
    cp "${OUTPUT_DIR}/latest.json" "${OUTPUT_DIR}/previous.json" 2>/dev/null || true
    cp "$CHUKO_ENRICHED" "${OUTPUT_DIR}/latest.json"
    echo "中古: enriched データを配置 (from ${CHUKO_ENRICHED})" >&2
else
    echo "警告: enriched-chuko の latest.json が見つかりません（前回データを維持）" >&2
    ls -R enriched-chuko/ 2>/dev/null || echo "  enriched-chuko/ ディレクトリ自体が存在しません" >&2
fi

# enriched-shinchiku の latest_shinchiku.json を配置
SHINCHIKU_ENRICHED=""
for candidate in "enriched-shinchiku/latest_shinchiku.json" "enriched-shinchiku/results/latest_shinchiku.json"; do
    if [ -f "$candidate" ]; then
        SHINCHIKU_ENRICHED="$candidate"
        break
    fi
done
if [ -n "$SHINCHIKU_ENRICHED" ]; then
    cp "${OUTPUT_DIR}/latest_shinchiku.json" "${OUTPUT_DIR}/previous_shinchiku.json" 2>/dev/null || true
    cp "$SHINCHIKU_ENRICHED" "${OUTPUT_DIR}/latest_shinchiku.json"
    echo "新築: enriched データを配置 (from ${SHINCHIKU_ENRICHED})" >&2
else
    echo "警告: enriched-shinchiku の latest_shinchiku.json が見つかりません（前回データを維持）" >&2
    ls -R enriched-shinchiku/ 2>/dev/null || echo "  enriched-shinchiku/ ディレクトリ自体が存在しません" >&2
fi

# transactions
if [ -f "transactions/transactions.json" ]; then
    cp "transactions/transactions.json" "${OUTPUT_DIR}/transactions.json"
    echo "成約実績: データを配置" >&2
fi

# ──────────────────────────── is_new フラグ注入 ────────────────────────────

echo "--- is_new フラグ注入 ---" >&2

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

# ──────────────────────────── 価格変動・掲載日数・競合物件数・投資スコア注入 ────────────────────────────

echo "--- 価格変動・掲載日数・競合・投資スコア注入 ---" >&2

python3 -c "
import json, sys
sys.path.insert(0, '.')
from report_utils import inject_price_history, inject_first_seen_at, inject_competing_count, load_json
from investment_enricher import enrich_investment_scores
from pathlib import Path

out = '${OUTPUT_DIR}'

cur = load_json(Path(f'{out}/latest.json'))
prev = load_json(Path(f'{out}/previous.json'), missing_ok=True, default=[])

inject_price_history(cur, prev or None)
inject_first_seen_at(cur, prev or None)
inject_competing_count(cur)

tx_data = None
tx_path = Path(f'{out}/transactions.json')
if tx_path.exists():
    tx_json = json.load(open(tx_path, encoding='utf-8'))
    tx_data = {}
    for bg in tx_json.get('building_groups', []):
        ward = bg.get('ward', '').replace('区', '')
        if ward not in tx_data:
            tx_data[ward] = {'transaction_count': 0}
        tx_data[ward]['transaction_count'] += bg.get('transaction_count', 0)
enrich_investment_scores(cur, tx_data)

with open(f'{out}/latest.json', 'w', encoding='utf-8') as f:
    json.dump(cur, f, ensure_ascii=False)

scored = sum(1 for r in cur if r.get('listing_score') is not None)
history = sum(1 for r in cur if len(r.get('price_history', [])) > 1)
print(f'中古: スコア {scored}/{len(cur)}件, 価格変動あり {history}件', file=sys.stderr)

cur_s = load_json(Path(f'{out}/latest_shinchiku.json'), missing_ok=True, default=[])
prev_s = load_json(Path(f'{out}/previous_shinchiku.json'), missing_ok=True, default=[])
if cur_s:
    inject_price_history(cur_s, prev_s or None)
    inject_first_seen_at(cur_s, prev_s or None)
    inject_competing_count(cur_s)
    enrich_investment_scores(cur_s, tx_data)
    with open(f'{out}/latest_shinchiku.json', 'w', encoding='utf-8') as f:
        json.dump(cur_s, f, ensure_ascii=False)
    scored_s = sum(1 for r in cur_s if r.get('listing_score') is not None)
    print(f'新築: スコア {scored_s}/{len(cur_s)}件', file=sys.stderr)
" || echo "投資スコア注入失敗（続行）" >&2

# ──────────────────────────── 供給トレンド生成 ────────────────────────────

echo "--- 供給トレンド生成 ---" >&2

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

# ──────────────────────────── 地図生成 ────────────────────────────

echo "--- 地図生成 ---" >&2
_t=$(date +%s)

SHINCHIKU_FLAG=""
if [ -s "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
    SHINCHIKU_FLAG="--shinchiku ${OUTPUT_DIR}/latest_shinchiku.json"
fi

python3 scripts/build_map_viewer.py "${OUTPUT_DIR}/latest.json" $SHINCHIKU_FLAG \
    || echo "地図生成失敗（続行）" >&2
echo "[TIMING] build_map_viewer: $(( ($(date +%s) - _t) ))s" >&2

# ジオコーディングキャッシュクリーンアップ
python3 scripts/geocode.py || true

# 東京都地域危険度 GeoJSON (初回のみ)
RISK_GEOJSON_DIR="${OUTPUT_DIR}/risk_geojson"
if [ ! -f "${RISK_GEOJSON_DIR}/building_collapse_risk.geojson" ]; then
    echo "東京都地域危険度 GeoJSON を生成中（初回のみ）..." >&2
    python3 scripts/convert_risk_geojson.py 2>&1 \
        || echo "GeoJSON 変換失敗（続行）" >&2
fi

# ──────────────────────────── レポート生成 ────────────────────────────

echo "--- レポート生成 ---" >&2
_t=$(date +%s)

REPORT_URL_ARG=""
MAP_URL_ARG=""
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    REPORT_URL="https://github.com/${GITHUB_REPOSITORY}/blob/${GITHUB_REF_NAME}/scraping-tool/results/report/report.md"
    REPORT_URL_ARG="--report-url ${REPORT_URL}"
    MAP_URL="https://htmlpreview.github.io/?https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${GITHUB_REF_NAME}/scraping-tool/results/map_viewer.html"
    MAP_URL_ARG="--map-url ${MAP_URL}"
fi

if [ -f "${OUTPUT_DIR}/previous.json" ]; then
    python3 generate_report.py "${OUTPUT_DIR}/latest.json" \
        --compare "${OUTPUT_DIR}/previous.json" \
        -o "$REPORT" $REPORT_URL_ARG $MAP_URL_ARG
else
    python3 generate_report.py "${OUTPUT_DIR}/latest.json" \
        -o "$REPORT" $REPORT_URL_ARG $MAP_URL_ARG
fi
cp "$REPORT" "${OUTPUT_DIR}/report_${DATE}.md"
echo "[TIMING] report: $(( ($(date +%s) - _t) ))s" >&2

# ──────────────────────────── プッシュ通知 ────────────────────────────

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
    python3 scripts/send_push.py --new-count "$NEW_CHUKO" --shinchiku-count "$NEW_SHINCHIKU" \
        || echo "プッシュ通知送信失敗（続行）" >&2
fi

# ──────────────────────────── Slack 通知 ────────────────────────────

if [ "$IS_SLACK_TIME" = "true" ] && [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    echo "Slack 通知送信中..." >&2
    python3 slack_notify.py \
        "${OUTPUT_DIR}/latest.json" \
        "${OUTPUT_DIR}/previous.json" \
        "$REPORT" \
        || echo "Slack 通知失敗（続行）" >&2
fi

# ──────────────────────────── ログアップロード ────────────────────────────

if [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ] && [ -f "${OUTPUT_DIR}/scraping_log.txt" ]; then
    python3 upload_scraping_log.py "${OUTPUT_DIR}/scraping_log.txt" --status success 2>&1 \
        || echo "ログアップロード失敗（続行）" >&2
fi

# ──────────────────────────── クリーンアップ ────────────────────────────

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

# enriched-* ワーキングディレクトリを削除
rm -rf enriched-chuko enriched-shinchiku transactions

# ──────────────────────────── データ品質検証 ────────────────────────────

echo "--- データ品質検証 ---" >&2
python3 scripts/validate_data.py "${OUTPUT_DIR}/latest.json" \
    --previous "${OUTPUT_DIR}/previous.json" --label "中古" \
    || echo "データ品質検証（中古）で問題が検出されました" >&2
if [ -s "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
    python3 scripts/validate_data.py "${OUTPUT_DIR}/latest_shinchiku.json" \
        --previous "${OUTPUT_DIR}/previous_shinchiku.json" --label "新築" \
        || echo "データ品質検証（新築）で問題が検出されました" >&2
fi

# ──────────────────────────── キャッシュクリーンアップ ────────────────────────────

echo "--- キャッシュクリーンアップ ---" >&2
python3 scripts/cache_manager.py --stats --cleanup || echo "キャッシュクリーンアップ失敗（続行）" >&2

echo "=== Finalize 完了 ===" >&2
echo "レポート: $REPORT" >&2
