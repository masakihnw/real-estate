#!/bin/bash
# WF2 finalize ジョブ用スクリプト
# 全 enrich ジョブの成果物を結合し、レポート生成・通知・コミットを行う。
# 一部ジョブが失敗しても利用可能なデータで最善の結果を出力する。
#
# 引数:
#   --is-slack-time true|false  Slack 通知を送信するかどうか
#   --has-changes true|false    スクレイピングで変更が検出されたか（false の場合、処理をスキップして Slack のみ実行）
#   --date YYYYMMDD_HHMMSS      実行日時ラベル

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# ──────────────────────────── 引数パース ────────────────────────────

IS_SLACK_TIME=false
HAS_CHANGES=true
DATE=$(TZ=Asia/Tokyo date +%Y%m%d_%H%M%S)

while [[ $# -gt 0 ]]; do
    case $1 in
        --is-slack-time) IS_SLACK_TIME="$2"; shift 2 ;;
        --has-changes) HAS_CHANGES="$2"; shift 2 ;;
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
echo "has_changes: ${HAS_CHANGES}, is_slack_time: ${IS_SLACK_TIME}" >&2

if [ "$HAS_CHANGES" = "true" ]; then

# ──────────────────────────── キャッシュマージ ────────────────────────────

echo "--- キャッシュマージ ---" >&2

# 各ジョブが更新した可能性のあるキャッシュをマージ
for cache_file in geocode_cache.json sumai_surfin_cache.json floor_plan_storage_manifest.json station_cache.json reverse_geocode_cache.json building_units.json mansion_review_cache.json; do
    UPDATES=""
    for job_dir in enriched-chuko-core enriched-chuko-sumai enriched-chuko-mansion enriched-shinchiku; do
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

# 3ジョブの enriched 成果物をフィールドレベルマージ
CHUKO_SOURCES=""
for job_dir in enriched-chuko-core enriched-chuko-sumai enriched-chuko-mansion; do
    for candidate in "${job_dir}/latest.json" "${job_dir}/results/latest.json"; do
        if [ -f "$candidate" ]; then
            CHUKO_SOURCES="${CHUKO_SOURCES} $candidate"
            echo "  中古ソース発見: $candidate" >&2
            break
        fi
    done
done

if [ -n "$CHUKO_SOURCES" ]; then
    # ベースファイルを決定（raw があれば raw、なければ現在の latest）
    BASE=""
    for candidate in "scrape-results/latest_raw.json" "results/latest_raw.json"; do
        if [ -f "$candidate" ]; then
            BASE="$candidate"
            break
        fi
    done
    if [ -z "$BASE" ]; then
        BASE="${OUTPUT_DIR}/latest.json"
    fi

    cp "${OUTPUT_DIR}/latest.json" "${OUTPUT_DIR}/previous.json" 2>/dev/null || true
    python3 scripts/merge_enrichments.py \
        --base "$BASE" \
        --enriched $CHUKO_SOURCES \
        --output "${OUTPUT_DIR}/latest.json"
    echo "中古: ${CHUKO_SOURCES} をマージ完了" >&2
else
    echo "警告: enriched-chuko の成果物が1つも見つかりません（前回データを維持）" >&2
    for job_dir in enriched-chuko-core enriched-chuko-sumai enriched-chuko-mansion; do
        ls -R "${job_dir}/" 2>/dev/null || echo "  ${job_dir}/ ディレクトリ自体が存在しません" >&2
    done
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

# ──────────────────────────── 画像 Storage アップロード ────────────────────────────

echo "--- 画像 Storage アップロード ---" >&2
_t=$(date +%s)

if [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
    if [ -f "${OUTPUT_DIR}/latest.json" ]; then
        python3 upload_floor_plans.py \
            --input "${OUTPUT_DIR}/latest.json" \
            --output "${OUTPUT_DIR}/latest.json" \
            --max-time 20 || echo "upload_floor_plans（中古）失敗（続行）" >&2
    fi

    if [ -s "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
        python3 upload_floor_plans.py \
            --input "${OUTPUT_DIR}/latest_shinchiku.json" \
            --output "${OUTPUT_DIR}/latest_shinchiku.json" \
            --max-time 10 || echo "upload_floor_plans（新築）失敗（続行）" >&2
    fi
else
    echo "FIREBASE_SERVICE_ACCOUNT 未設定のためスキップ" >&2
fi

echo "[TIMING] upload_floor_plans: $(( ($(date +%s) - _t) ))s" >&2

# ──────────────────────────── is_new フラグ注入 ────────────────────────────

# ──────────────────────────── SQLite DB 同期 ────────────────────────────

echo "--- SQLite DB 同期 ---" >&2
_t=$(date +%s)

python3 scripts/sync_db.py --output-dir "${OUTPUT_DIR}" \
    || echo "SQLite DB 同期失敗（続行）" >&2

echo "[TIMING] sync_db: $(( ($(date +%s) - _t) ))s" >&2

# ──────────────────────────── is_new フラグ注入 ────────────────────────────

echo "--- is_new フラグ注入 ---" >&2

python3 scripts/finalize_helpers.py inject-new --output-dir "${OUTPUT_DIR}" \
    || echo "is_new 注入失敗（続行）" >&2

# ──────────────────────────── 価格変動・掲載日数・競合物件数・投資スコア注入 ────────────────────────────

echo "--- 価格変動・掲載日数・競合・投資スコア注入 ---" >&2

python3 scripts/finalize_helpers.py inject-investment --output-dir "${OUTPUT_DIR}" \
    || echo "投資スコア注入失敗（続行）" >&2

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
    read NEW_CHUKO NEW_BUILDING NEW_ROOM NEW_SHINCHIKU <<< $(python3 scripts/finalize_helpers.py count-new --output-dir "${OUTPUT_DIR}" 2>/dev/null || echo "0 0 0 0")
    python3 scripts/send_push.py --new-count "$NEW_CHUKO" --shinchiku-count "$NEW_SHINCHIKU" \
        --new-building-count "$NEW_BUILDING" --new-room-count "$NEW_ROOM" \
        --latest "${OUTPUT_DIR}/latest.json" --latest-shinchiku "${OUTPUT_DIR}/latest_shinchiku.json" \
        || echo "プッシュ通知送信失敗（続行）" >&2
fi

fi  # end HAS_CHANGES

# ──────────────────────────── Slack 通知 ────────────────────────────
# 毎回実行。前回通知時点のスナップショット (previous_slack.json) と比較し、
# 差分（新規追加 or 削除）があれば通知する。通知後にスナップショットを更新。

if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    SLACK_PREVIOUS="${OUTPUT_DIR}/previous_slack.json"
    if [ ! -f "$SLACK_PREVIOUS" ]; then
        SLACK_PREVIOUS="${OUTPUT_DIR}/previous.json"
        echo "previous_slack.json が存在しないため previous.json をフォールバックとして使用" >&2
    fi

    echo "Slack 通知送信中（前回通知からの差分）..." >&2
    python3 slack_notify.py \
        "${OUTPUT_DIR}/latest.json" \
        "$SLACK_PREVIOUS" \
        "$REPORT" \
        || echo "Slack 通知失敗（続行）" >&2

    cp "${OUTPUT_DIR}/latest.json" "${OUTPUT_DIR}/previous_slack.json"
    echo "previous_slack.json を更新しました" >&2
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
rm -rf enriched-chuko-core enriched-chuko-sumai enriched-chuko-mansion enriched-shinchiku transactions scrape-results

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
