#!/usr/bin/env bash
# UserPromptSubmit フック: テスト設計/レビュー/実装系のプロンプトを検知し、
# qa-personas スキル（7人の意地悪なQA）の自動起動を毎回リマインドする。
# 標準出力に出した文字列は、そのターンのコンテキストに追記される（exit 0 のとき）。
#
# 設計方針:
# - 失敗してもユーザーのプロンプト処理を止めない（必ず exit 0）。
# - 関連しないプロンプト（雑談・質問のみ等）では何も出力せず、コンテキストを汚さない。
set -u

# stdin の JSON から prompt を取り出す（python3 は本リポジトリの必須依存=3.11）。
input="$(cat)"
prompt="$(printf '%s' "$input" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("prompt",""))' 2>/dev/null || true)"

# テスト/レビュー/実装に関係するキーワード（日英）。大文字小文字を無視。
pattern='テスト|test|レビュー|review|バグ|bug|デグレ|regression|実装|implement|修正|fix|feat|リファクタ|refactor|スクレイ|scraper|パーサ|parser|enrich|マイグレ|migration|swift|ios|supabase|firestore|dedup|観点'

shopt -s nocasematch
if [[ "$prompt" =~ $pattern ]]; then
  cat <<'EOF'
[qa-personas auto] このターンがテスト設計・テストレビュー・コードレビュー・実装（iOS / スクレイパー・enricher / マイグレーション / AI分析）に該当する場合は、ユーザーの明示指示が無くても `.claude/skills/qa-personas` スキルを起動すること。7人のQAペルソナ(P1〜P7)で観点漏れ（正常系偏重・データ整合・回帰デグレ・単一ソース突合・フェイルクローズ）を各視点1つ以上確認し、新機能か移行/構造変更かで観点軸を切り替える。該当しない雑談・単純質問の場合はこのリマインドを無視してよい。
EOF
fi

exit 0
