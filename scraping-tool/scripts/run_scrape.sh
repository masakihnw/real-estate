#!/bin/bash
# WF1: Scrape Listings 用スクリプト
# 中古+新築を並列スクレイピングし、変更検出結果を metadata.json に出力する。
# GitHub Actions の artifact 経由で WF2 (Enrich & Report) にデータを渡す。
#
# 出力:
#   results/latest_raw.json         - 中古スクレイピング結果 (enrichment 前)
#   results/latest_shinchiku_raw.json - 新築スクレイピング結果 (enrichment 前)
#   results/metadata.json           - 変更検出結果 + 件数 + Slack 通知フラグ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_DIR="results"
mkdir -p "$OUTPUT_DIR"

DATE=$(TZ=Asia/Tokyo date +%Y%m%d_%H%M%S)

echo "=== WF1: Scrape Listings ===" >&2
echo "日時: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')（JST）" >&2

# ──────────────────────────── Phase 1: 並列スクレイピング ────────────────────────────

CHUKO_RAW="${OUTPUT_DIR}/latest_raw.json"
SHINCHIKU_RAW="${OUTPUT_DIR}/latest_shinchiku_raw.json"

echo "--- 中古 + 新築 並列スクレイピング開始 ---" >&2

_t_start=$(date +%s)

python3 main.py --source suumo --property-type chuko -o "$CHUKO_RAW" &
CHUKO_PID=$!

python3 main.py --source suumo --property-type shinchiku -o "$SHINCHIKU_RAW" &
SHINCHIKU_PID=$!

echo "[並列] 中古 (PID: $CHUKO_PID) + 新築 (PID: $SHINCHIKU_PID) 実行中..." >&2

CHUKO_EXIT=0
SHINCHIKU_EXIT=0

wait $CHUKO_PID || CHUKO_EXIT=$?
wait $SHINCHIKU_PID || SHINCHIKU_EXIT=$?

_t_end=$(date +%s)
echo "[TIMING] scraping: $(( (_t_end - _t_start) / 60 ))m $(( (_t_end - _t_start) % 60 ))s" >&2

# 中古バリデーション (必須)
if [ "$CHUKO_EXIT" -ne 0 ] || [ ! -s "$CHUKO_RAW" ]; then
    echo "エラー: 中古スクレイピングに失敗しました (exit=$CHUKO_EXIT)" >&2
    exit 1
fi

CHUKO_COUNT=$(python3 -c "import json; print(len(json.load(open('$CHUKO_RAW'))))")
if [ "$CHUKO_COUNT" -eq 0 ]; then
    echo "エラー: 中古データが 0 件です" >&2
    exit 1
fi
echo "中古取得件数: ${CHUKO_COUNT}件" >&2

# 新築バリデーション (失敗許容)
SHINCHIKU_COUNT=0
if [ "$SHINCHIKU_EXIT" -ne 0 ] || [ ! -s "$SHINCHIKU_RAW" ]; then
    echo "警告: 新築スクレイピングに失敗しました (exit=$SHINCHIKU_EXIT)（続行）" >&2
    rm -f "$SHINCHIKU_RAW"
else
    SHINCHIKU_COUNT=$(python3 -c "import json; print(len(json.load(open('$SHINCHIKU_RAW'))))")
    echo "新築取得件数: ${SHINCHIKU_COUNT}件" >&2
fi

# ──────────────────────────── Phase 2: 変更検出 ────────────────────────────

echo "--- 変更検出 ---" >&2

HAS_CHANGES=false

# 中古: committed latest.json と比較
if [ -f "${OUTPUT_DIR}/latest.json" ]; then
    if python3 check_changes.py "$CHUKO_RAW" "${OUTPUT_DIR}/latest.json"; then
        echo "中古: 変更あり" >&2
        HAS_CHANGES=true
    else
        echo "中古: 変更なし" >&2
    fi
else
    echo "中古: 初回実行（変更あり扱い）" >&2
    HAS_CHANGES=true
fi

# 新築: committed latest_shinchiku.json と比較
if [ -s "$SHINCHIKU_RAW" ] && [ -f "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
    if python3 check_changes.py "$SHINCHIKU_RAW" "${OUTPUT_DIR}/latest_shinchiku.json"; then
        echo "新築: 変更あり" >&2
        HAS_CHANGES=true
    else
        echo "新築: 変更なし" >&2
    fi
elif [ -s "$SHINCHIKU_RAW" ]; then
    echo "新築: 初回実行（変更あり扱い）" >&2
    HAS_CHANGES=true
fi

# ──────────────────────────── Phase 3: Slack 通知時間判定 ────────────────────────────

IS_SLACK_TIME=false
CURRENT_HOUR=$(date -u +%H)

# 22:00 UTC (7:00 JST) の回 = Slack 通知タイム
if [ "$CURRENT_HOUR" = "22" ]; then
    IS_SLACK_TIME=true
fi

# ──────────────────────────── Phase 4: metadata.json 出力 ────────────────────────────

cat > "${OUTPUT_DIR}/metadata.json" <<EOF
{
  "has_changes": ${HAS_CHANGES},
  "chuko_count": ${CHUKO_COUNT},
  "shinchiku_count": ${SHINCHIKU_COUNT},
  "is_slack_time": ${IS_SLACK_TIME},
  "date": "${DATE}"
}
EOF

echo "=== WF1 完了 ===" >&2
echo "has_changes: ${HAS_CHANGES}" >&2
echo "chuko_count: ${CHUKO_COUNT}" >&2
echo "shinchiku_count: ${SHINCHIKU_COUNT}" >&2
echo "is_slack_time: ${IS_SLACK_TIME}" >&2
