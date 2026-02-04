#!/bin/bash
# 定期実行用スクリプト: 物件情報を取得し、Markdownレポートを生成

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

echo "=== 物件情報取得開始 ===" >&2
echo "日時: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')（JST）" >&2

# 1. データ取得（SUUMO + HOME'S、結果がなくなるまで全ページ取得）
python3 main.py --source both -o "$CURRENT"

if [ ! -s "$CURRENT" ]; then
    echo "エラー: データが取得できませんでした" >&2
    exit 1
fi

COUNT=$(python3 -c "import json; print(len(json.load(open('$CURRENT'))))")
echo "取得件数: ${COUNT}件" >&2

# 2. 前回結果と比較し、変更がなければレポート・通知をスキップ（スクレイピングのみ実行）
if [ -f "${OUTPUT_DIR}/latest.json" ]; then
    if ! python3 check_changes.py "$CURRENT" "${OUTPUT_DIR}/latest.json"; then
        echo "変更なし（レポート・通知をスキップ）" >&2
        rm -f "$CURRENT"
        exit 0
    fi
fi

# GitHub Actions 実行時は results/report へのハイパーリンク用 URL を渡す
REPORT_URL_ARG=""
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    REPORT_URL="https://github.com/${GITHUB_REPOSITORY}/blob/${GITHUB_REF_NAME}/scraping-tool/results/report/report.md"
    REPORT_URL_ARG="--report-url ${REPORT_URL}"
fi

# 3. 前回結果（latest.json）があれば差分レポート生成、なければ通常レポート
if [ -f "${OUTPUT_DIR}/latest.json" ]; then
    echo "前回結果と比較: latest.json" >&2
    python3 generate_report.py "$CURRENT" --compare "${OUTPUT_DIR}/latest.json" -o "$REPORT" $REPORT_URL_ARG
else
    echo "初回実行（差分なし）" >&2
    python3 generate_report.py "$CURRENT" -o "$REPORT" $REPORT_URL_ARG
fi
# 今回実行分のレポートをタイムスタンプ付きで保存（Slackリンク用・results/直下）
cp "$REPORT" "${OUTPUT_DIR}/report_${DATE}.md"

# 4. 最新結果を latest.json に保存。Slack 差分用に前回を previous.json へ退避してから上書き
cp "${OUTPUT_DIR}/latest.json" "${OUTPUT_DIR}/previous.json" 2>/dev/null || true
cp "$CURRENT" "${OUTPUT_DIR}/latest.json"

# 4.5. Notion 同期（NOTION_TOKEN と NOTION_DATABASE_ID が設定されている場合のみ。失敗してもレポート・コミットは行う）
if [ -n "${NOTION_TOKEN:-}" ] && [ -n "${NOTION_DATABASE_ID:-}" ]; then
    echo "Notion に同期中..." >&2
    python3 notion-tool/sync_to_notion.py "${OUTPUT_DIR}/latest.json" --compare "${OUTPUT_DIR}/previous.json" || echo "Notion 同期は失敗しました（レポート・コミットは続行）" >&2
fi

# 5. JSON は不要のため削除（md 生成に使った current_*.json を削除）
rm -f "$CURRENT"
for f in "${OUTPUT_DIR}"/current_*.json; do
    [ -f "$f" ] || continue
    rm -f "$f" 2>/dev/null || true
done

# 6. 最新以外の report_*.md を results/report/old/ に格納
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
echo "最新: ${OUTPUT_DIR}/latest.json" >&2

# 7. Git操作（オプション: --no-git でスキップ可能）
if [ "$1" != "--no-git" ]; then
    # リポジトリルートを探す（scraping-tool/ から親ディレクトリへ）
    REPO_ROOT="$SCRIPT_DIR"
    while [ ! -d "$REPO_ROOT/.git" ] && [ "$REPO_ROOT" != "/" ]; do
        REPO_ROOT=$(dirname "$REPO_ROOT")
    done
    
    if [ -d "$REPO_ROOT/.git" ]; then
        echo "=== Git操作開始 ===" >&2
        cd "$REPO_ROOT"
        REPORT_FILE="$SCRIPT_DIR/results/report/report.md"
        
        # 変更があるか確認
        if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files -o --exclude-standard scraping-tool/results/)" ]; then
            echo "変更なし（スキップ）" >&2
        else
            # 変更サマリーを取得（差分レポートから）
            if [ -f "$REPORT_FILE" ]; then
                SUMMARY=$(grep -A 3 "## 📊 変更サマリー" "$REPORT_FILE" 2>/dev/null | grep -E "🆕|🔄|❌" | head -3 | sed 's/^[[:space:]]*- //' | tr '\n' ' ' || echo "")
            fi
            
            # コミットメッセージ生成
            COMMIT_MSG="Update listings: ${DATE}"
            if [ -n "$SUMMARY" ]; then
                COMMIT_MSG="${COMMIT_MSG}

${SUMMARY}"
            fi
            COMMIT_MSG="${COMMIT_MSG}

取得件数: ${COUNT}件
レポート: scraping-tool/${REPORT_DIR}/report.md"
            
            # ステージング・コミット・プッシュ
            git add scraping-tool/results/ 2>/dev/null || true
            if git diff --cached --quiet; then
                echo "コミットする変更がありません" >&2
            else
                git commit -m "$COMMIT_MSG" || echo "コミット失敗（変更がない可能性）" >&2
                
                # プッシュ（リモートが設定されている場合のみ）
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
