# real-estate (public)

本プロジェクトの正規リポジトリは [https://github.com/masakihnw/real-estate](https://github.com/masakihnw/real-estate) です。
GitHub Actions（物件情報の定期取得、レポート、Slack通知）は、このリポジトリだけで実行します。

10年住み替え前提で「インデックスに勝つ」ための中古マンション購入を検討するための、
iOSアプリ、スクレイピングパイプライン、クラウドバックエンドです。

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
│   ├── supabase_sync.py    #   Supabase への同期
│   ├── slack_notify.py     #   差分・ウォッチリスト値下げの Slack 通知（既定で送信停止）
│   └── tests/              #   pytest（CI で実行）
├── supabase/migrations/    # Supabase スキーマ（3桁連番。採番規律は .claude/CLAUDE.md 参照）
├── configs/commute/        # 通勤先の設定
├── data/                   # 通勤駅マスターの雛形とサンプルデータ
├── scripts/                # Firestore から Supabase への移行スクリプト
├── docs/                   # 仕様書（SPECIFICATION.md は一部自動生成）
├── design/                 # iOS デザインシステム
├── ref/                    # 購入検討の参考資料
└── .github/workflows/      # 定期スクレイピング・enrichment・監視・バックアップ・CI
```

データの流れは次のとおりです。スクレイパーが物件を取得し、dedup、enrichment（通勤、ハザード、AIスコアリング）を経て、Supabaseに保存します。iOSアプリは、そのデータを読みます。Firebaseは、iOSの認証、FCM、写真Storageに使う。

## セットアップ

### Python（scraping-tool）

```bash
# Python 3.11 固定（.python-version 参照）
cd scraping-tool
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
playwright install chromium   # ブラウザ enrichment を使う場合
```

lintとテストのコマンドは、[.claude/CLAUDE.md](.claude/CLAUDE.md) の Commands に書いてあります。

主要な環境変数（GitHub ActionsではSecretsで渡す）は次のとおりです。
`SUPABASE_URL` / `SUPABASE_SERVICE_KEY` / `ANTHROPIC_API_KEY` /
`SLACK_WEBHOOK_URL` / `FIREBASE_SERVICE_ACCOUNT`（FCM送信とスクレイピングログのアップロードに使う）

### iOS（real-estate-ios）

```bash
brew install xcodegen
```

プロジェクトの再生成とテストのコマンドは、[.claude/CLAUDE.md](.claude/CLAUDE.md) の Commands に書いてあります。新規ファイルを追加したときは、必ず `xcodegen generate` で再生成します。

TestFlightへの配布は `deploy.sh --ios` で行います（API Keyは設定済み）。

## 設定の単一ソース

スクレイピング条件、買い手コンテキスト、ランタイム上書きの正準ソースと再生成手順は、
[.claude/CLAUDE.md](.claude/CLAUDE.md) の「設定の単一ソース」に書いてあります。

## 定期更新

物件情報は、GitHub Actionsが1日4回（JST 9:00、15:00、18:00、20:00）に自動で更新します。

- 最新のレポート: `scraping-tool/results/report/` に生成される。`.gitignore` 対象のため、リポジトリには含まれない。
- 実行履歴: GitHub Actionsの [Actions タブ](https://github.com/masakihnw/real-estate/actions) で確認できます。

Slack通知は、2026-07-07から全経路を停止した。`slack_notify.py` は、環境変数 `SLACK_NOTIFICATIONS_ENABLED=1` を設定したときだけ送信する。
Backfill HOME'S Images、Detect Delisted Listings、Notification Watchdog、Cron Watchdogの4つのworkflowは、GitHub側で手動で無効化してあります（2026-10-02に `gh workflow list --all` で確認）。経緯と再開手順は [docs/purchase-decision-toyocho.md](docs/purchase-decision-toyocho.md) にあります。

## ドキュメント

- 購入条件（ドラフト）: [docs/10year-index-mansion-conditions-draft.md](docs/10year-index-mansion-conditions-draft.md)
- 仕様書: [docs/SPECIFICATION.md](docs/SPECIFICATION.md)
- スクレイピングツールの詳細: [scraping-tool/README.md](scraping-tool/README.md)

## 開発ルール

リポジトリ衛生、マイグレーション採番、スクレイパーのフェイルセーフ原則などは、
[.claude/CLAUDE.md](.claude/CLAUDE.md) に書いてあります。
