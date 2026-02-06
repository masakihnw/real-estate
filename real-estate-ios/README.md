# 物件情報 iOS アプリ（RealEstateApp）

スクレイピングで取得した物件を一覧・詳細で閲覧し、新規追加をアプリ内通知で知らせる iPhone アプリです。**Notion・Slack は連携しない**（DB 機能はアプリに集約）。**HIG・OOUI・iOS 26 Liquid Glass** に則ったデザインで、iOS 17–25 ではシステムの Material 等にフォールバックします。

## 要件・設計

- **[docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)** — 要件と方針（データ取得・通知・対象 OS 等）
- **[docs/DB-STRATEGY.md](docs/DB-STRATEGY.md)** — DB の持ち方（保守・UX・パフォーマンス）
- **[docs/DESIGN.md](docs/DESIGN.md)** — HIG・OOUI・Liquid Glass のデザイン指針

## 機能

- **物件一覧**: ローカル DB に保存された物件を一覧表示。検索・ソート（価格・徒歩・専有面積など）。
- **物件詳細**: タップで詳細表示。SUUMO/HOME'S の詳細ページを Safari で開ける。
- **データ同期**: 設定で指定した JSON URL（例: GitHub raw の `latest.json`）から取得し、ローカルを更新。
- **新規物件の通知**: 更新時に新規が検出されたらローカル通知（プッシュ）を発火。

## 開発環境

- Xcode 15+
- iOS 17+（SwiftData 利用のため）
- Swift 5.9+

## プロジェクトの開き方

1. Xcode で **File → New → Project** を選択。
2. **iOS → App** を選び、次のように設定する。
   - Product Name: `RealEstateApp`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **SwiftData**
   - 保存先: このリポジトリの **real-estate-ios** フォルダの**外**（親の real-estate など）に作成するか、または **real-estate-ios** 内に作成して既存の **RealEstateApp** フォルダを上書き／マージする。
3. 既存の **RealEstateApp** フォルダの中身（RealEstateAppApp.swift, ContentView.swift, Models/, Views/, Services/）を、Xcode で作成したプロジェクトに**ドラッグ＆ドロップ**で追加する。  
   - または、新規プロジェクト作成時に **real-estate-ios** を選択し、テンプレートの App の代わりに既存の **RealEstateApp** をターゲットのソースとして指定する。
4. **SwiftData** を使うため、ターゲットの **Frameworks** に SwiftData が含まれていることを確認（通常は iOS App なら標準で利用可能）。
5. ビルドしてシミュレータまたは実機で実行。

### 既存フォルダをそのまま使う場合

- この **real-estate-ios/RealEstateApp** を Xcode の「Add Files to "RealEstateApp"」で追加し、App のエントリポイントを **RealEstateAppApp.swift** にすれば、そのままビルドできる構成になっています。

## データソースの設定

1. アプリ起動後、**設定** タブを開く。
2. **一覧JSONのURL** に、`scraping-tool/results/latest.json` を配信している URL を入力する。  
   - 例: GitHub の **raw** URL  
     `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/scraping-tool/results/latest.json`
3. **URLを保存** で保存し、**今すぐ更新** または一覧タブでプルダウンして更新する。

## ディレクトリ構成

```
real-estate-ios/
├── README.md
├── docs/
│   ├── REQUIREMENTS.md   # 要件・方針
│   ├── DB-STRATEGY.md    # DB 設計
│   └── DESIGN.md         # HIG・OOUI・Liquid Glass
└── RealEstateApp/
    ├── RealEstateAppApp.swift
    ├── ContentView.swift
    ├── Design/
    │   └── DesignSystem.swift
    ├── Models/
    │   └── Listing.swift
    ├── Views/
    │   ├── ListingListView.swift
    │   ├── ListingDetailView.swift
    │   └── SettingsView.swift
    └── Services/
        └── ListingStore.swift
```

## リポジトリ全体との関係

- 物件データの形式は **scraping-tool/results/latest.json** に準拠しています。
- スクレイピング・Slack・Notion 同期は従来どおり **scraping-tool** と **.github/workflows** で実行し、アプリは「取得済みの一覧を表示・通知」する役割です。
