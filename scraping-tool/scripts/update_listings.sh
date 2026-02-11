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

CURRENT_SHINCHIKU="${OUTPUT_DIR}/current_shinchiku_${DATE}.json"

echo "=== 物件情報取得開始 ===" >&2
echo "日時: $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S')（JST）" >&2

# 1. データ取得（中古: SUUMO + HOME'S、結果がなくなるまで全ページ取得）
echo "--- 中古マンション取得 ---" >&2
python3 main.py --source both --property-type chuko -o "$CURRENT"

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

# 1.5. 新築データ取得（SUUMO + HOME'S）
echo "--- 新築マンション取得 ---" >&2
python3 main.py --source both --property-type shinchiku -o "$CURRENT_SHINCHIKU" || echo "新築取得エラー（中古は続行）" >&2

SHINCHIKU_COUNT=0
if [ -s "$CURRENT_SHINCHIKU" ]; then
    SHINCHIKU_COUNT=$(python3 -c "import json; print(len(json.load(open('$CURRENT_SHINCHIKU'))))")
fi
echo "新築取得件数: ${SHINCHIKU_COUNT}件" >&2
echo "取得件数: ${COUNT}件" >&2

# 2. 前回結果と比較し、中古・新築いずれかに変更があればパイプラインを続行
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

# 新築の変更チェック
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

if [ "$HAS_CHANGES" = false ]; then
    echo "中古・新築ともに変更なし（レポート・通知をスキップ）" >&2
    rm -f "$CURRENT" "$CURRENT_SHINCHIKU"
    exit 0
fi

# GitHub Actions 実行時は results/report と物件マップへのリンク用 URL を渡す（スマホからも閲覧可）
REPORT_URL_ARG=""
MAP_URL_ARG=""
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    REPORT_URL="https://github.com/${GITHUB_REPOSITORY}/blob/${GITHUB_REF_NAME}/scraping-tool/results/report/report.md"
    REPORT_URL_ARG="--report-url ${REPORT_URL}"
    MAP_URL="https://htmlpreview.github.io/?https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/${GITHUB_REF_NAME}/scraping-tool/results/map_viewer.html"
    MAP_URL_ARG="--map-url ${MAP_URL}"
fi

# 3. 前回結果（latest.json）があれば差分レポート生成、なければ通常レポート（地図URLは再生成後に付与）
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

# 4.4. 総戸数・階数・権利形態キャッシュ更新（SUUMO 詳細ページを取得して data/building_units.json と data/html_cache/ を更新）
echo "総戸数・階数・権利形態キャッシュを更新中（詳細ページ取得のため時間がかかります）..." >&2
python3 scripts/build_units_cache.py "${OUTPUT_DIR}/latest.json" || echo "キャッシュの更新に失敗しました（続行）" >&2

# 4.4.1. 今回の latest.json にキャッシュをマージし、レポートを再生成
#         → report.md と Slack（latest.json を参照）の両方に階・戸数・権利が反映される
python3 scripts/merge_detail_cache.py "${OUTPUT_DIR}/latest.json" || echo "詳細キャッシュのマージに失敗しました（続行）" >&2

# 4.4.2. 物件マップ用 HTML を生成（レポート・Slack に地図リンクを付与するため。初回はジオコーディングで時間がかかることがあります）
echo "物件マップを生成中..." >&2
python3 scripts/build_map_viewer.py "${OUTPUT_DIR}/latest.json" || echo "地図の生成に失敗しました（続行）" >&2

# 4.4.3. ジオコーディングキャッシュの座標を latest.json に埋め込み（hazard enricher で使用）
echo "ジオコーディングを埋め込み中..." >&2
python3 scripts/embed_geocode.py "${OUTPUT_DIR}/latest.json" || echo "embed_geocode に失敗しました（続行）" >&2

echo "レポートを再生成（詳細キャッシュ・地図リンク反映）..." >&2
if [ -f "${OUTPUT_DIR}/previous.json" ]; then
    python3 generate_report.py "${OUTPUT_DIR}/latest.json" --compare "${OUTPUT_DIR}/previous.json" -o "$REPORT" $REPORT_URL_ARG $MAP_URL_ARG
else
    python3 generate_report.py "${OUTPUT_DIR}/latest.json" -o "$REPORT" $REPORT_URL_ARG $MAP_URL_ARG
fi
cp "$REPORT" "${OUTPUT_DIR}/report_${DATE}.md"

# 4.5. Notion 同期（NOTION_TOKEN と NOTION_DATABASE_ID が設定されている場合のみ。失敗してもレポート・コミットは行う）
if [ -n "${NOTION_TOKEN:-}" ] && [ -n "${NOTION_DATABASE_ID:-}" ]; then
    echo "Notion に同期中..." >&2
    python3 notion-tool/sync_to_notion.py "${OUTPUT_DIR}/latest.json" --compare "${OUTPUT_DIR}/previous.json" || echo "Notion 同期は失敗しました（レポート・コミットは続行）" >&2
fi

# 4.6. 新築結果を latest_shinchiku.json に保存
if [ -s "$CURRENT_SHINCHIKU" ]; then
    cp "${OUTPUT_DIR}/latest_shinchiku.json" "${OUTPUT_DIR}/previous_shinchiku.json" 2>/dev/null || true
    cp "$CURRENT_SHINCHIKU" "${OUTPUT_DIR}/latest_shinchiku.json"
    echo "新築: ${OUTPUT_DIR}/latest_shinchiku.json に保存" >&2
fi

# 4.7a. ハザード enrichment（座標があれば GSI タイル + 東京地域危険度を判定）
echo "ハザード enrichment 実行中..." >&2
python3 hazard_enricher.py --input "${OUTPUT_DIR}/latest.json" --output "${OUTPUT_DIR}/latest.json" || echo "ハザード enrichment (中古) 失敗（続行）" >&2
if [ -s "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
    python3 hazard_enricher.py --input "${OUTPUT_DIR}/latest_shinchiku.json" --output "${OUTPUT_DIR}/latest_shinchiku.json" || echo "ハザード enrichment (新築) 失敗（続行）" >&2
fi

# 4.7. 住まいサーフィン enrichment（SUMAI_USER / SUMAI_PASS が設定されている場合のみ）
if [ -n "${SUMAI_USER:-}" ] && [ -n "${SUMAI_PASS:-}" ]; then
    echo "住まいサーフィン enrichment 実行中..." >&2
    python3 sumai_surfin_enricher.py --input "${OUTPUT_DIR}/latest.json" --output "${OUTPUT_DIR}/latest.json" || echo "住まいサーフィン enrichment (中古) 失敗（続行）" >&2
    if [ -s "${OUTPUT_DIR}/latest_shinchiku.json" ]; then
        python3 sumai_surfin_enricher.py --input "${OUTPUT_DIR}/latest_shinchiku.json" --output "${OUTPUT_DIR}/latest_shinchiku.json" || echo "住まいサーフィン enrichment (新築) 失敗（続行）" >&2
    fi
else
    echo "住まいサーフィン: SUMAI_USER / SUMAI_PASS 未設定のためスキップ" >&2
fi

# 4.7b. enrichment 完了後にレポートを最終再生成（ハザード・住まいサーフィン情報を反映）
echo "レポートを最終再生成（enrichment 反映）..." >&2
if [ -f "${OUTPUT_DIR}/previous.json" ]; then
    python3 generate_report.py "${OUTPUT_DIR}/latest.json" --compare "${OUTPUT_DIR}/previous.json" -o "$REPORT" $REPORT_URL_ARG $MAP_URL_ARG
else
    python3 generate_report.py "${OUTPUT_DIR}/latest.json" -o "$REPORT" $REPORT_URL_ARG $MAP_URL_ARG
fi
cp "$REPORT" "${OUTPUT_DIR}/report_${DATE}.md"

# 4.8. リモートプッシュ通知（FIREBASE_SERVICE_ACCOUNT が設定されている場合のみ）
if [ -n "${FIREBASE_SERVICE_ACCOUNT:-}" ]; then
    echo "プッシュ通知送信中..." >&2
    # 新着件数を計算（前回との差分）
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
    python3 scripts/send_push.py --new-count "$NEW_CHUKO" --shinchiku-count "$NEW_SHINCHIKU" || echo "プッシュ通知送信失敗（続行）" >&2
else
    echo "プッシュ通知: FIREBASE_SERVICE_ACCOUNT 未設定のためスキップ" >&2
fi

# 5. JSON は不要のため削除（md 生成に使った current_*.json を削除）
rm -f "$CURRENT" "$CURRENT_SHINCHIKU"
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
echo "最新（中古）: ${OUTPUT_DIR}/latest.json" >&2
echo "最新（新築）: ${OUTPUT_DIR}/latest_shinchiku.json" >&2

# 7. Git操作（オプション: --no-git でスキップ可能）
# 変更検出は上記の check_changes.py（current vs latest.json）で行っており、--no-git とは独立。
# --no-git 時もレポート・通知は実行済み。このブロックは commit/push のみスキップする。
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
