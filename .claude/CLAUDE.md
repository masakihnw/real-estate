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

## Rules

- Verify no Swift compilation errors after iOS changes
- Scraping tools must handle rate limiting and error recovery
- Never hardcode API keys; use environment variables
- Test scraper changes against a small dataset before full run
- 方針が固まったタイミングと実装が終わったタイミングの2回、コードレビュー（code-reviewer agent）を必ず実施する
- 実装中はこまめにユニットテストを書き、テストが通ることを確認しながら進める（省略禁止）

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

## Supabase マイグレーション

- 新規マイグレーションは `supabase/migrations/` の**既存最大番号 + 1**を3桁ゼロ埋めで採番。
  採番前に必ず `ls supabase/migrations/ | sort | tail` で最大番号を確認する（過去に 025 が衝突）。
- 適用済みマイグレーションのファイル名・内容は変更しない。修正は新番号で行う。
- マイグレーション適用は Claude が直接実行せず、SQL を用意してユーザーに適用を依頼する。

## 設定の単一ソース

- スクレイピング条件の正は `real-estate-ios/RealEstateApp/ScrapingConfigMetadata.json`
  （iOS と `scraping-tool/config.py` フォールバックの両方が参照）。片側だけ変更しない。
- デフォルト値を変更したら `python3 scripts/generate_scraping_conditions_doc.py --write-spec`
  で `docs/SPECIFICATION.md` を再生成する（テストが同期を検証している）。
- ランタイム上書きは Supabase `scraping_config` テーブル（`supabase_config_loader.py`）が現行。
  `firestore_config_loader.py` は旧実装。新規機能を足さない。

## スクレイパー・エチケット / フェイルセーフ

- リクエスト間隔は `config.py` の `*_REQUEST_DELAY_SEC` を下回らない。新サイトは3秒以上から。
- パース0件は「正常な終端」と「botブロック/構造変更」を区別する。
  `EMPTY_PARSE_TOLERANCE`（連続2回で停止）パターンを必ず適用する（livable / suumo 参照）。
- フェイル時は「取りこぼし側に倒す」フェイルクローズを原則とする
  （取得失敗を「掲載終了」と誤判定して大量削除しない）。
- パース例外は握り潰さず、最低限 debug ログ + 件数集計を残す。