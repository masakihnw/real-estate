# real-estate (public)

**本プロジェクトの正規リポジトリ**: [https://github.com/masakihnw/real-estate](https://github.com/masakihnw/real-estate)
GitHub Actions（物件情報の定期取得・レポート・Slack 通知）はこのリポジトリのみで実行します。

10年住み替え前提で「インデックスに勝つ」ための中古マンション購入を検討するための
**iOS アプリ + スクレイピングパイプライン + クラウドバックエンド**。

## 全体構成

```
real-estate-public/
├── real-estate-ios/        # SwiftUI iOS アプリ「物件情報」(XcodeGen / SwiftData)
│   ├── RealEstateApp/      #   Views / Models / Services / Utilities / Design
│   ├── RealEstateAppTests/ #   ユニットテスト（Swift Testing）
│   └── RealEstateWidget/   #   ホーム画面ウィジェット
├── scraping-tool/          # Python スクレイパー + enrichment パイプライン
│   ├── *_scraper.py        #   suumo / homes / athome / nomucom / rehouse / livable / stepon
│   ├── *_enricher.py       #   通勤時間 / ハザード / e-Stat / reinfolib / 住まいサーフィン
│   ├── claude_*.py         #   Claude API による投資分析・テキスト抽出・画像分類
│   ├── supabase_sync.py    #   Supabase への同期（正系）
│   ├── slack_notify.py     #   差分・ウォッチリスト値下げの Slack 通知
│   └── tests/              #   pytest（CI で実行）
├── supabase/migrations/    # Supabase スキーマ（3桁連番。採番規律は .claude/CLAUDE.md 参照）
├── configs/                # スクレイピング設定
├── scripts/                # 移行・ドキュメント生成スクリプト
├── docs/                   # 仕様書（SPECIFICATION.md は一部自動生成）
└── .github/workflows/      # 定期スクレイピング / Python テスト / iOS ビルド+テスト
```

データフロー: スクレイパー → dedup → enrichment（通勤・ハザード・AI スコアリング）→
Supabase（正系）/ Firestore（いいね・コメント共有）→ iOS アプリ / Slack 通知

## セットアップ

### Python（scraping-tool）

```bash
# Python 3.11 固定（.python-version 参照）
cd scraping-tool
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
playwright install chromium   # ブラウザ enrichment を使う場合

# lint + テスト
ruff check . && python3 -m pytest tests/
```

主要な環境変数（GitHub Actions では Secrets で注入）:
`SUPABASE_URL` / `SUPABASE_SERVICE_KEY` / `ANTHROPIC_API_KEY` /
`SLACK_WEBHOOK_URL` / `FIREBASE_SERVICE_ACCOUNT`（レガシー）

### iOS（real-estate-ios）

```bash
brew install xcodegen
cd real-estate-ios
xcodegen generate    # 新規ファイル追加時は必ず再生成
xcodebuild test -project RealEstateApp.xcodeproj -scheme RealEstateApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

TestFlight 配布は `deploy.sh --ios`（API Key 設定済み）。

## 設定の単一ソース

スクレイピング条件（価格帯・面積・築年など）の正は
`real-estate-ios/RealEstateApp/ScrapingConfigMetadata.json`。
ランタイム上書きは Supabase `scraping_config` テーブル。
変更時は `python3 scripts/generate_scraping_conditions_doc.py --write-spec` で
`docs/SPECIFICATION.md` を再生成する（テストで同期を検証）。

## 定期更新

物件情報は GitHub Actions で自動更新されています（毎日朝8時 JST）。

- **最新レポート**: [scraping-tool/results/report/report.md](scraping-tool/results/report/report.md)（検索条件・物件一覧・差分を含む）
- **実行履歴**: GitHub Actions の [Actions タブ](https://github.com/masakihnw/real-estate/actions) で確認可能

## ドキュメント

- **購入条件（ドラフト）**: [docs/10year-index-mansion-conditions-draft.md](docs/10year-index-mansion-conditions-draft.md)
- **仕様書**: [docs/SPECIFICATION.md](docs/SPECIFICATION.md)
- **スクレイピングツール詳細**: [scraping-tool/README.md](scraping-tool/README.md)

## 開発ルール

詳細は [.claude/CLAUDE.md](.claude/CLAUDE.md) を参照
（リポジトリ衛生・マイグレーション採番・スクレイパーのフェイルセーフ原則など）。
