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

```
real-estate-public/
├── real-estate-ios/       # Swift iOS app (SwiftUI)
├── scraping-tool/         # Python scrapers (suumo, athome, nomucom, etc.)
├── supabase/migrations/   # Supabase DB migrations
├── scripts/               # Migration scripts
├── configs/               # Scraping configs
└── data/                  # Scraped data output
```

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

## 開発フロー（必ずPR経由・デグレ防止）

直接 main へ push しない。修正・機能追加は必ず以下を踏む:

1. **専用ブランチを切る**（`fix/...` `feat/...` `chore/...`）。1つの変更=1つのブランチ=1つのPR。
2. **レグレッションテストを用意/更新する**（デグレ検知の自動化が前提）:
   - iOS: 変更箇所のロジックを `RealEstateAppTests/` のテストで固定する。
   - パイプライン: パーサ/enricher の純関数テスト＋ステージ間結線の
     `scraping-tool/tests/test_pipeline_smoke.py` を維持する。
3. **PR を作成**（`gh pr create`）。`.github/workflows/ci.yml` が自動で
   ruff + pytest（Python変更時）/ build + 全テスト（iOS変更時）を走らせる。
4. **`ci-gate` が緑になってからマージ**する。main はブランチ保護で
   `ci-gate` 必須・直push禁止（レビュー承認は不要なのでソロでも自分でマージ可）。

CI は `ci.yml` の単一ゲートに集約済み。`changes` ジョブが変更領域（python/ios）を
判定し、関係ジョブのみ実行、`ci-gate` が結果を集約して1ステータスを返す
（paths フィルタ未起動による必須チェックの永久待ちを回避するため）。

## Rules

- Verify no Swift compilation errors after iOS changes
- Scraping tools must handle rate limiting and error recovery
- Never hardcode API keys; use environment variables
- Test scraper changes against a small dataset before full run
- 方針が固まったタイミングと実装が終わったタイミングの2回、コードレビュー（code-reviewer agent）を必ず実施する
- 実装中はこまめにユニットテストを書き、テストが通ることを確認しながら進める（省略禁止）
- テスト設計・テストレビュー・code-review の観点出しは `.claude/skills/qa-personas`（7人の意地悪なQA）を
  チェックリストとして使う。正常系偏重・データ整合・回帰デグレ・単一ソース突合の漏れを各ペルソナで潰す。

## リポジトリ衛生（Claude Code 厳守）

- `git add .` / `git add -A` は使用禁止。変更したファイルをパス指定で個別に add する。
- 以下は絶対にコミットしない（再生成可能 or 機密 or 肥大化）:
  - `scraping-tool/data/*_html_cache/`（html_cache / shinchiku_html_cache / homes_html_cache）
  - `*.bak` / `*.backup.json` / `scraping-tool/enriched-chuko-sumai/`
  - `real-estate-ios/build/`（.xcarchive・embedded.mobileprovision を含む）
  - `.venv/` / `.env` / `*.db-wal` / `*.db-shm`
- 新しいキャッシュ・中間ファイルを生成するコードを追加したら、同じコミットで `.gitignore` に登録する。
- `old/` ディレクトリと `results/**/old/` に新規ファイルを作らない（履歴は Git に残る）。

## Python 環境

- Python は **3.11** 固定（`.python-version` / CI / ローカル `.venv` を一致させる）。
- 依存追加時は `scraping-tool/requirements.txt` に追記し、インストール確認する。
- `ruff check .`（scraping-tool 内）が通ること。`print()` でなく `logger.get_logger` を使う。
- スクレイパー/enricher 実装時はパース関数を純粋関数として切り出し、`tests/` に最低1つテストを書く。

## iOS

- 新規 Swift ファイル追加後は `xcodegen generate` でプロジェクト再生成が必要。
- ロジックは View の private computed property に直接書かず、テスト可能なユーティリティ
  （例: `Utilities/WatchlistFilter.swift`）に抽出する。
- Mac 版（Mac Catalyst）は廃止済み。Mac Catalyst 向けコード・ビルド設定を追加しない。
- `DateFormatter` は `static let` + `Locale(identifier: "en_US_POSIX")` で共有する（和暦端末対策）。

### de-PII 外部 plist（必須機密リソース）— ログイン不能を絶対に再発させない

`AllowedEmails.plist` / `CommuteOffices.plist` は de-PII で外部 plist 化された機密リソース。
`.gitignore` 対象でローカルにのみ存在し、**ビルドに含めないと事故になる**:
- `AllowedEmails.plist` 欠落 → 許可リスト空＝全アカウント拒否（fail-closed）→ **誰もログインできない**。
- `CommuteOffices.plist` 欠落 → 通勤時間が座標0,0で壊れる。

過去の事故: de-PII 時に plist 不在のまま `project.pbxproj` を再生成・コミットし、参照が抜けた
pbxproj から TestFlight をビルドしてログイン不能になった。再発防止として以下を**厳守**する:

- `project.pbxproj` は **gitignore 対象**でコミット禁止。ビルド前に必ず `xcodegen generate` で再生成する
  （ビルド番号の正は `project.yml`、生成物 pbxproj ではない）。
- `project.yml` の `sources` は `path: RealEstateApp`（フォルダ丸ごと）を維持する。**plist を明示ファイル列挙に
  変えない**（列挙にすると gitignore plist が漏れて参照が抜ける）。
- de-PII / 機密ファイルの plist 化・移動・削除を行ったら、**同じ作業内で**
  `cd real-estate-ios && ./scripts/verify_required_resources.sh` を実行して合格させる。
- TestFlight への配布は必ず `./scripts/deploy.sh --ios` 経由で行う。deploy.sh は
  アーカイブ前（ソース＋pbxproj 参照）とアップロード前（.app 同梱の最終確認）で
  `verify_required_resources.sh` を呼び、欠落時はアップロードを中止する。**この検証を迂回しない**。
- 必須リソースを増減したら `REQUIRED_PLISTS`（`scripts/verify_required_resources.sh`）も更新する。

## Supabase マイグレーション

- 新規マイグレーションは `supabase/migrations/` の**既存最大番号 + 1**を3桁ゼロ埋めで採番。
  採番前に必ず `ls supabase/migrations/ | sort | tail` で最大番号を確認する（過去に 025 が衝突）。
- 適用済みマイグレーションのファイル名・内容は変更しない。修正は新番号で行う。
- マイグレーションは **Claude が Supabase MCP (`execute_sql`) で直接適用する**。採番済みの
  `supabase/migrations/0XX_*.sql` は正（source of truth）としてコミットし、本番へは MCP で適用する。
  DDL は `CREATE OR REPLACE` 等で冪等にし、将来の CLI 再適用と衝突しないようにする。適用後は
  実データで効果を検証する。（旧運用の「ユーザーに適用を依頼」は廃止。）

## 設定の単一ソース

- スクレイピング条件の正は `real-estate-ios/RealEstateApp/ScrapingConfigMetadata.json`
  （iOS と `scraping-tool/config.py` フォールバックの両方が参照）。片側だけ変更しない。
- デフォルト値を変更したら `python3 scripts/generate_scraping_conditions_doc.py --write-spec`
  で `docs/SPECIFICATION.md` を再生成する（テストが同期を検証している）。
- ランタイム上書きは Supabase `scraping_config` テーブル（`supabase_config_loader.py`）が現行。
  `firestore_config_loader.py` は旧実装。新規機能を足さない。

### 買い手コンテキスト（AI購入分析）

- ドメインごとに**正準ソースは1ファイル**。片側だけ変更しない:
  - 買い手プロフィール（事実データ）= `scraping-tool/config/buyer_profile.json`
  - 購入戦略（全AIモジュール共有の判断ポリシー・築年/価格判断）= `scraping-tool/config/purchase_strategy.md`
  - モジュール別タスク定義（出力形式・評価手順）= `scraping-tool/config/prompts/<module>.md`
- ai_prompts の system_prompt は「購入戦略 → タスク定義」の合成。判断基準（予算・築年・NG条件等）は
  `purchase_strategy.md` だけに書き、タスク定義側にハードコードしない。
- いずれかを変更したら `cd scraping-tool && python3 scripts/generate_buyer_context.py --write` で
  `docs/BUYER_PROFILE.md` と `scraping-tool/out/*.sql` を再生成する（テストが同期を検証）。
- 実運用の正は Supabase（`buyer_profiles` / `ai_prompts`）。反映SQLの version は本番の
  max(version)+1 に採番する（`generate_buyer_context.py` の PROMPT_SPECS）。
  `ai_prompts` の本文変更は全 enrichment の再分析を誘発するため、
  `config.max_items_per_run` でバッチ制御する。
- `claude_investment_summarizer.py` のフォールバックは `purchase_strategy.md`＋
  `prompts/investment_summary.md` から合成する（ハードコードしない）。
- iOS `BuyerProfile.swift` の `preset` は手動同期（機械生成しない）。

## スクレイパー・エチケット / フェイルセーフ

- リクエスト間隔は `config.py` の `*_REQUEST_DELAY_SEC` を下回らない。新サイトは3秒以上から。
- パース0件は「正常な終端」と「botブロック/構造変更」を区別する。
  `EMPTY_PARSE_TOLERANCE`（連続2回で停止）パターンを必ず適用する（livable / suumo 参照）。
- フェイル時は「取りこぼし側に倒す」フェイルクローズを原則とする
  （取得失敗を「掲載終了」と誤判定して大量削除しない）。
- パース例外は握り潰さず、最低限 debug ログ + 件数集計を残す。