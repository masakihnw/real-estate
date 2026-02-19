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
    NEW_CHUKO=0
    NEW_SHINCHIKU=0
    if [ -f "${OUTPUT_DIR}/previous.json" ]; then
        NEW_CHUKO=$(python3 -c "
import json
cur = {item.get('url','') for item in json.load(open('${OUTPUT_DIR}/latest.json'))}
prev = {item.get('url','') for item in json.load(open('${OUTPUT_DIR}/previous.json'))}
print(len(cur - prev))
" 2>/dev/null || echo "0")
    fi
    if [ -f "${OUTPUT_DIR}/previous_shinchiku.json" ] && [ -f "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
        NEW_SHINCHIKU=$(python3 -c "
import json
cur = {item.get('url','') for item in json.load(open('${OUTPUT_DIR}/latest_shinchiku.json'))}
prev = {item.get('url','') for item in json.load(open('${OUTPUT_DIR}/previous_shinchiku.json'))}
print(len(cur - prev))
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

echo "=== Finalize 完了 ===" >&2
echo "レポート: $REPORT" >&2
