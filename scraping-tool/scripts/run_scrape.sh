#!/bin/bash
# WF1: Scrape Listings 用スクリプト
# 中古物件をスクレイピングし、変更検出結果を metadata.json に出力する。
# GitHub Actions の artifact 経由で WF2 (Enrich & Report) にデータを渡す。
# ※ 新築は 2026-06 に全面廃止（dd1bdb4）
#
# 出力:
#   results/latest_raw.json         - 中古スクレイピング結果 (enrichment 前)
#   results/metadata.json           - 変更検出結果 + 件数 + Slack 通知フラグ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_DIR="results"
mkdir -p "$OUTPUT_DIR"

DATE=$(TZ=Asia/Tokyo date +%Y%m%d_%H%M%S)
STARTED_HOUR_UTC=$(date -u +%H)

echo "=== WF1: Scrape Listings ===" >&2
echo "日時: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')（JST）" >&2

# ──────────────────────────── Phase 1: スクレイピング ────────────────────────────

CHUKO_RAW="${OUTPUT_DIR}/latest_raw.json"

echo "--- 中古スクレイピング開始 ---" >&2

_t_start=$(date +%s)

CHUKO_EXIT=0
python3 main.py --source all --property-type chuko -o "$CHUKO_RAW" || CHUKO_EXIT=$?

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

# ──────────────────────────── Phase 3: Slack 通知時間判定 ────────────────────────────

IS_SLACK_TIME=false

# JST 9:00 (UTC 0:00) の回で Slack 通知（Routine②③のドラフトを朝一で送信）
# GHA cron は最大3-5時間遅延するため、UTC 0-5 をスラック通知時間帯として許容する。
# 次のスケジュール(UTC 6)は遅延しても UTC 8以降のため重複しない。
# 二重送信は slack_notify.py の notification_state CAS で防止。
case "$STARTED_HOUR_UTC" in
    0|00|01|02|03|04|05) IS_SLACK_TIME=true ;;
esac

# ──────────────────────────── Phase 4: metadata.json 出力 ────────────────────────────

cat > "${OUTPUT_DIR}/metadata.json" <<EOF
{
  "has_changes": ${HAS_CHANGES},
  "chuko_count": ${CHUKO_COUNT},
  "is_slack_time": ${IS_SLACK_TIME},
  "date": "${DATE}"
}
EOF

echo "=== WF1 完了 ===" >&2
echo "has_changes: ${HAS_CHANGES}" >&2
echo "chuko_count: ${CHUKO_COUNT}" >&2
echo "is_slack_time: ${IS_SLACK_TIME}" >&2
