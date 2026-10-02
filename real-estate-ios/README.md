# 物件情報iOSアプリ（RealEstateApp）

スクレイピングで取得した中古マンションを、一覧、詳細、地図で閲覧するiPhone・iPadアプリです。新規物件が追加されると通知が届きます。NotionとSlackは連携せず、DB機能はアプリに集約した構成です。デザインはHIG、OOUI、iOS 26 Liquid Glassに沿います。iOS 17から25ではシステムのスタイルを使います。

## 要件と設計

- [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) 要件と方針（データ取得、通知、対象OSなど）
- [docs/DB-STRATEGY.md](docs/DB-STRATEGY.md) DBの持ち方（保守、UX、パフォーマンス）
- [docs/DESIGN.md](docs/DESIGN.md) HIG、OOUI、Liquid Glassのデザイン指針
- [docs/FIREBASE-SETUP.md](docs/FIREBASE-SETUP.md) Firebaseのセットアップ手順
- [docs/TODO.md](docs/TODO.md) 実装の完了履歴と未確定事項

## 機能

- 今日: ブリーフ、変化カード、スワイプの入口、週次相場を表示します。
- さがす: 物件をリストと地図で切り替えて探します。検索、ソート、フィルタ、比較ができます。地図ではハザードマップと東京都の地域危険度を重ねられます。
- マイリスト: いいねした物件を表示し、CSVで共有できます。
- 物件詳細: SUUMOやHOME'Sの詳細ページをSafariで開けます。いいねとコメントを家族間で共有します。
- 通知: 新規物件が検出されると、ローカル通知とFCMのリモートプッシュで知らせます。
- 設定: データ取得元、通知、アカウントなどを設定します。

## 開発環境

- Xcode 16以上（`project.yml` の `xcodeVersion` は16.0）
- iOS 17以上（SwiftDataを使うため）
- Swift 5.9
- XcodeGen（`project.yml` から `RealEstateApp.xcodeproj` を生成します）

## プロジェクトの開き方

1. 事前に、次の2つの外部plistを `RealEstateApp/` に置きます。どちらも `.gitignore` の対象で、リポジトリには含まれません。
   - `AllowedEmails.plist`: ログインを許可するアカウント。ひな形は `AllowedEmails.sample.plist` です。ファイルがないと全アカウントが拒否され、ログインできません。
   - `CommuteOffices.plist`: 通勤先の情報。ひな形は `CommuteOffices.sample.plist` です。
2. `real-estate-ios` ディレクトリで `xcodegen generate` を実行し、`RealEstateApp.xcodeproj` を生成します。ファイルを追加したときも再生成が必要です。`project.pbxproj` はコミットしません。
3. `RealEstateApp.xcodeproj` をXcodeで開き、シミュレータか実機でビルドして実行します。

必須plistの有無は `./scripts/verify_required_resources.sh` で確認できます。TestFlightへ配布するときは `./scripts/deploy.sh --ios` を実行してください。deploy.shがアーカイブの前とアップロードの前にこの確認を呼び、欠落があればアップロードを中止します。

## データソースの設定

既定の取得元はSupabaseです。初回起動時にデータが空であれば、アプリが自動で取得します。手動で更新するには、一覧タブでプルダウンしてください。

カスタムURLの一覧JSONから取得することもできます。

1. 設定タブで「Supabase API」をオフにします。
2. 「カスタム URL 設定」を開き、「中古マンション JSON URL」に、一覧JSONを配信しているURLを入力します。たとえばGitHubのrawのURLです。
3. 保存ボタンを押してから更新します。

「Supabase API」をオンに戻すと、既定のSupabase取得に戻ります。

## ディレクトリ構成

```
real-estate-ios/
├── README.md
├── project.yml           # XcodeGenの設定
├── docs/                 # 要件、DB設計、デザイン、Firebase手順、TODO
├── scripts/              # deploy.sh、verify_required_resources.sh
├── color-preview/        # カラースキームとUIのプレビューHTML
├── RealEstateApp/
│   ├── RealEstateAppApp.swift
│   ├── ContentView.swift
│   ├── Design/           # デザインシステム
│   ├── Models/           # Listingなどのモデルとフィルタ
│   ├── Services/         # 同期、認証、通知などのサービス
│   ├── Utilities/        # テスト可能なロジック
│   └── Views/            # 画面
├── RealEstateAppTests/   # ユニットテスト
└── RealEstateWidget/     # ウィジェット
```

## リポジトリ全体との関係

- スクレイピング、enrich、Slack通知は `scraping-tool` と `.github/workflows` で実行します。結果はSupabaseに書き込まれます。
- アプリは取得済みの物件を表示し、通知します。
