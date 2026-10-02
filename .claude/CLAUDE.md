# real-estate-public

## Project Overview

Real estate search and analysis platform with iOS app, web scraping pipeline, and cloud backend.

## Stack

| Component | Tech |
|-----------|------|
| iOS App | Swift, SwiftUI, Xcode (`real-estate-ios/`) |
| Scraping | Python (`scraping-tool/`) |
| Backend | Firebase (Firestore, Storage), Supabase (migrating) |
| Infra | `firebase.json`, `firestore.rules`, `storage.rules` |
| Build | Xcode via `project.yml` (XcodeGen) |

## ECC Rules

- iOS app: Follow `~/.claude/rules/ecc/swift/`
- Scraping tools: Follow `~/.claude/rules/ecc/python/`

## Key Directories

ディレクトリ構成の正本は [README.md](../README.md) の「全体構成」です。

## Commands

```bash
# iOS: プロジェクト再生成（新規ファイル追加時に必須）→ ビルド＋テスト
cd real-estate-ios && xcodegen generate
xcodebuild test -project RealEstateApp.xcodeproj -scheme RealEstateApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
# ※ シミュレータ名は `xcrun simctl list devices available` で実在するものを使う

# Python: lint + テスト
cd scraping-tool && ruff check . && python3 -m pytest tests/

# Run a scraper
cd scraping-tool && python suumo_scraper.py
```

このコマンド一覧が正本です。README.mdのセットアップ手順は、ここへリンクします。

## 開発フロー（必ずPR経由・デグレ防止）

直接mainへpushしない。修正と機能追加は必ず次の手順を踏む。

1. **専用ブランチを切る**（`fix/...` `feat/...` `chore/...`）。1つの変更につき1つのブランチ、1つのPRとする。
2. **レグレッションテストを用意または更新する**。デグレ検知の自動化が前提である。
   - iOS: 変更箇所のロジックを `RealEstateAppTests/` のテストで固定する。
   - パイプライン: パーサとenricherの純関数テストに加えて、ステージ間の結線を確かめる
     `scraping-tool/tests/test_pipeline_smoke.py` を維持する。
3. **PRを作成する**（`gh pr create`）。`.github/workflows/ci.yml` が自動で、
   Python変更時はruffとpytest、iOS変更時はbuildと全テストを走らせる。
4. **`ci-gate` が緑になってからマージする**。mainはブランチ保護で
   `ci-gate` 必須・直push禁止になっている（レビュー承認は不要なので、ソロでも自分でマージできる）。

CIは `ci.yml` の単一ゲートに集約済みである。`changes` ジョブが変更領域（python/ios）を
判定して関係するジョブだけを実行し、`ci-gate` が結果を集約して1つのステータスを返す
（pathsフィルタで起動しなかった必須チェックを永久に待ち続ける状態を避けるため）。

## Rules

- iOSを変更したら、Swiftのコンパイルエラーがないことを確認する
- スクレイピングツールは、レート制限とエラーからの復旧を扱えるようにする
- APIキーをハードコードしない。環境変数を使う
- スクレイパーを変更したら、フルランの前に小さなデータセットで試す
- 方針が固まったときと実装が終わったときの2回、コードレビュー（code-reviewer agent）を必ず実施する
- 実装中はこまめにユニットテストを書き、テストが通ることを確認しながら進める（省略禁止）
- 観点出しでは、ユーザーの明示指示がなくても `.claude/skills/qa-personas`（7人の意地悪なQA）スキルを
  自動的に起動する。観点出しの対象は、テスト設計、テストレビュー、code-review、
  実装（iOS、スクレイパーとenricher、マイグレーション、AI分析）である。
  正常系への偏り、データ整合、回帰デグレ、単一ソース突合の漏れを、各ペルソナで洗い出す。
  `UserPromptSubmit` フックも、該当するターンで自動的にリマインドする（設定は `.claude/hooks/qa_personas_autoload.sh`）。

## リポジトリ衛生（Claude Codeが厳守する）

- `git add .` と `git add -A` は使用禁止。変更したファイルをパス指定で個別にaddする。
- 次のものは絶対にコミットしない（再生成できる、機密である、または肥大化するため）。
  - `scraping-tool/data/*_html_cache/`（html_cache / shinchiku_html_cache / homes_html_cache）
  - `*.bak` / `*.backup.json` / `scraping-tool/enriched-chuko-sumai/`
  - `real-estate-ios/build/`（.xcarchive・embedded.mobileprovision を含む）
  - `.venv/` / `.env` / `*.db-wal` / `*.db-shm`
- 新しいキャッシュや中間ファイルを生成するコードを追加したら、同じコミットで `.gitignore` に登録する。
- `old/` ディレクトリと `results/**/old/` に新規ファイルを作らない（履歴はGitに残る）。

## Python 環境

- Pythonは3.11に固定する（`.python-version`、CI、ローカルの `.venv` を一致させる）。
- 依存を追加したら `scraping-tool/requirements.txt` に追記し、インストールできることを確認する。
- `ruff check .`（scraping-tool内）が通ること。`print()` でなく `logger.get_logger` を使う。
- スクレイパーとenricherを実装するときは、パース関数を純粋関数として切り出し、`tests/` に最低1つテストを書く。

## iOS

- 新規Swiftファイルを追加したら、`xcodegen generate` でプロジェクトを再生成する。
- ロジックはViewのprivate computed propertyに直接書かず、テストできるユーティリティ
  （例: `Utilities/WatchlistFilter.swift`）に抽出する。
- Mac版（Mac Catalyst）は廃止済み。Mac Catalyst向けのコードとビルド設定を追加しない。
- `DateFormatter` は `static let` と `Locale(identifier: "en_US_POSIX")` で共有する（和暦端末への対策）。

### de-PII外部plist（必須機密リソース）。ログイン不能を絶対に再発させない

`AllowedEmails.plist` と `CommuteOffices.plist` は、de-PIIで外部plist化された機密リソースである。
`.gitignore` 対象でローカルにのみ存在する。ビルドに含めないと、次の障害が起きる。
- `AllowedEmails.plist` が欠けると、許可リストが空になり全アカウントを拒否する（fail-closed）。誰もログインできない。
- `CommuteOffices.plist` が欠けると、座標が0,0になり、通勤時間を正しく計算できない。

過去に、de-PII時にplistが存在しないまま `project.pbxproj` を再生成してコミットし、参照が抜けた
pbxprojからTestFlightをビルドして、ログインできなくなった。再発防止として次を厳守する。

- `project.pbxproj` は `.gitignore` 対象でコミット禁止。ビルド前に必ず `xcodegen generate` で再生成する
  （ビルド番号の正は `project.yml` であり、生成物のpbxprojではない）。
- `project.yml` の `sources` は `path: RealEstateApp`（フォルダ丸ごと）を維持する。plistを明示ファイルの列挙に
  変えない（列挙にすると、`.gitignore` 対象のplistが漏れて参照が抜ける）。
- de-PIIや機密ファイルのplist化、移動、削除を行ったら、同じ作業の中で
  `cd real-estate-ios && ./scripts/verify_required_resources.sh` を実行して合格させる。
- TestFlightへの配布は必ず `./scripts/deploy.sh --ios` 経由で行う。deploy.shは
  アーカイブ前（ソースとpbxprojの参照）とアップロード前（.app同梱の最終確認）で
  `verify_required_resources.sh` を呼び、欠落があればアップロードを中止する。この検証を迂回しない。
- 必須リソースを増減したら、`REQUIRED_PLISTS`（`scripts/verify_required_resources.sh`）も更新する。

## Supabase マイグレーション

- 新規マイグレーションは `supabase/migrations/` の既存最大番号に1を足し、3桁のゼロ埋めで採番する。
  採番前に必ず `ls supabase/migrations/ | sort | tail` で最大番号を確認する（過去に025が衝突した）。
- 適用済みマイグレーションのファイル名と内容は変更しない。修正は新番号で行う。
- マイグレーションはClaudeがSupabase MCP（`execute_sql`）で直接適用する。採番済みの
  `supabase/migrations/0XX_*.sql` は正としてコミットし、本番へはMCPで適用する。
  DDLは `CREATE OR REPLACE` などで冪等にし、将来のCLI再適用と衝突しないようにする。適用後は
  実データで効果を検証する（旧運用の「ユーザーに適用を依頼」は廃止）。

## 設定の単一ソース

- スクレイピング条件の正は `real-estate-ios/RealEstateApp/ScrapingConfigMetadata.json` である
  （iOSと `scraping-tool/config.py` のフォールバックの両方が参照する）。片側だけ変更しない。
- デフォルト値を変更したら、`cd scraping-tool && python3 scripts/generate_scraping_conditions_doc.py --write-spec`
  で `docs/SPECIFICATION.md` を再生成する（テストが同期を検証している）。
- ランタイムの上書きは、Supabaseの `scraping_config` テーブル（`supabase_config_loader.py`）が現行である。
  旧実装の `firestore_config_loader.py` は削除済み。

### 買い手コンテキスト（AI購入分析）

- ドメインごとに、正準ソースは1ファイルとする。片側だけ変更しない。
  - 買い手プロフィール（事実データ）は `scraping-tool/config/buyer_profile.json`
  - 購入戦略（全AIモジュールが共有する判断ポリシーと、築年・価格の判断）は `scraping-tool/config/purchase_strategy.md`
  - モジュール別のタスク定義（出力形式と評価手順）は `scraping-tool/config/prompts/<module>.md`
- ai_promptsのsystem_promptは「購入戦略 → タスク定義」の順に合成する。判断基準（予算、築年、NG条件など）は
  `purchase_strategy.md` だけに書き、タスク定義側にハードコードしない。
- いずれかを変更したら、`cd scraping-tool && python3 scripts/generate_buyer_context.py --write` で
  `docs/BUYER_PROFILE.md` と `scraping-tool/out/*.sql` を再生成する（テストが同期を検証している）。
- 実運用の正はSupabase（`buyer_profiles` と `ai_prompts`）である。反映SQLのversionは、本番の
  max(version)+1に採番する（`generate_buyer_context.py` の `PROMPT_SPECS`）。
  `ai_prompts` の本文を変更すると、全enrichmentの再分析が走る。そのため、
  `config.max_items_per_run` でバッチを制御する。
- `claude_investment_summarizer.py` のフォールバックは、`purchase_strategy.md` と
  `prompts/investment_summary.md` から合成する（ハードコードしない）。
- iOSの `BuyerProfile.swift` の `preset` は手動で同期する（機械生成しない）。

## スクレイパー・エチケット / フェイルセーフ

- リクエスト間隔は、`config.py` の `*_REQUEST_DELAY_SEC` を下回らない。新しいサイトは3秒以上から始める。
- パース0件が、正常な終端なのか、botブロックまたは構造変更なのかを区別する。
  `EMPTY_PARSE_TOLERANCE`（連続2回で停止）のパターンを必ず適用する（livableとsuumoを参照）。
- 失敗したときは、「取りこぼし側に倒す」フェイルクローズを原則とする
  （取得失敗を「掲載終了」と誤判定して大量削除しない）。
- パース例外を無視せず、最低限、debugログと件数の集計を残す。
