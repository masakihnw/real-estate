# 物件情報アプリ 総合仕様書

> **最終更新**: 2025-02-12  
> **ステータス**: 運用中  
> **リポジトリ**: https://github.com/masakihnw/real-estate

---

## 目次

1. [プロジェクト概要](#1-プロジェクト概要)
2. [システムアーキテクチャ](#2-システムアーキテクチャ)
3. [iOS アプリ仕様](#3-ios-アプリ仕様)
4. [スクレイピングツール仕様](#4-スクレイピングツール仕様)
5. [データモデル](#5-データモデル)
6. [Firebase 仕様](#6-firebase-仕様)
7. [CI/CD パイプライン](#7-cicd-パイプライン)
8. [購入条件・フィルタロジック](#8-購入条件フィルタロジック)
9. [非機能要件](#9-非機能要件)
10. [用語集](#10-用語集)

---

## 1. プロジェクト概要

### 1.1 目的

10年住み替え前提で「インデックス（年5%）に勝つ」ための中古・新築マンション購入を検討するためのツール群。SUUMO / HOME'S から物件情報を自動スクレイピングし、iOS アプリで閲覧・比較・評価を行う。

### 1.2 ターゲットユーザー

- 自分自身 + 家族（妻）
- TestFlight による限定配布
- Google サインインのメールアドレスホワイトリストで制御

### 1.3 プロジェクト構成

```
real-estate/
├── .github/workflows/         # CI/CD（GitHub Actions）
├── docs/                      # 購入条件・相談メモ・本仕様書
├── firebase.json              # Firebase 設定
├── firestore.rules            # Firestore セキュリティルール
├── storage.rules              # Firebase Storage ルール
├── real-estate-ios/           # iOS アプリ（SwiftUI + SwiftData）
│   ├── RealEstateApp/         # アプリ本体ソースコード
│   ├── docs/                  # iOS アプリ設計ドキュメント
│   └── project.yml            # XcodeGen 設定
└── scraping-tool/             # Python スクレイピングパイプライン
    ├── scripts/               # シェルスクリプト（update_listings.sh 等）
    ├── data/                  # キャッシュ・マスターデータ
    ├── results/               # 出力（latest.json, report.md 等）
    ├── docs/                  # セットアップ・技術ドキュメント
    └── tests/                 # pytest テスト
```

---

## 2. システムアーキテクチャ

### 2.1 全体構成図

```
┌────────────────────────────────────────────────────────────────────┐
│                    GitHub Actions（CI/CD）                          │
│  main.py → enrichers → generate_report.py → send_push.py          │
│  → upload_scraping_log.py → slack_notify.py → git commit & push    │
└────────────────────┬───────────────────────────────────────────────┘
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
┌──────────┐  ┌───────────┐  ┌──────────────┐
│ GitHub   │  │ Firebase  │  │ Slack        │
│ raw URL  │  │ (BaaS)    │  │ (Webhook)    │
│ JSON配信 │  │           │  │              │
└────┬─────┘  └─────┬─────┘  └──────────────┘
     │              │
     │    ┌─────────┴──────────────────────┐
     │    │ Firestore  : annotations,      │
     │    │              scraping_config,   │
     │    │              scraping_logs      │
     │    │ Auth       : Google Sign-In     │
     │    │ Storage    : 内見写真            │
     │    │ FCM        : プッシュ通知        │
     │    └─────────────────────────────────┘
     │              │
     ▼              ▼
┌────────────────────────────────────────────────────────────────────┐
│                  iOS アプリ（SwiftUI + SwiftData）                   │
│  ListingStore → SwiftData → UI                                     │
│  FirebaseSyncService ↔ Firestore                                   │
│  PhotoSyncService ↔ Firebase Storage                               │
│  CommuteTimeService → MKDirections                                 │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 技術スタック

| レイヤー | 技術 |
|---------|------|
| **iOS アプリ** | SwiftUI, SwiftData, MapKit, CoreLocation, PhotosUI, SafariServices |
| **認証** | Firebase Auth + Google Sign-In |
| **データ同期** | Firebase Firestore, Firebase Storage |
| **通知** | Firebase Cloud Messaging (FCM) + ローカル通知 |
| **スクレイピング** | Python 3.9, requests, BeautifulSoup4, lxml, Playwright |
| **データ配信** | GitHub raw URL（JSON） |
| **CI/CD** | GitHub Actions |
| **通知（開発者向け）** | Slack Webhook |
| **ビルド管理** | XcodeGen (project.yml) |

### 2.3 依存パッケージ

#### iOS（Swift Package Manager）

| パッケージ | バージョン | 用途 |
|-----------|-----------|------|
| Firebase | 12.9.0 | Auth, Firestore, Messaging, Storage |
| GoogleSignIn | 8.0.0 | Google サインイン |

#### Python（pip）

| パッケージ | バージョン | 用途 |
|-----------|-----------|------|
| requests | >=2.28.0,<3.0.0 | HTTP リクエスト |
| beautifulsoup4 | >=4.12.0,<5.0.0 | HTML パース |
| lxml | >=4.9.0,<6.0.0 | XML/HTML パーサー |
| pandas | >=2.0.0,<3.0.0 | データ分析 |
| pytest | >=7.0.0,<8.0.0 | テスト |
| PyJWT | >=2.8.0,<3.0.0 | JWT 生成（FCM用） |
| cryptography | >=41.0.0,<44.0.0 | 暗号処理 |
| Pillow | >=10.0.0,<12.0.0 | 画像処理 |
| firebase-admin | >=6.0.0,<7.0.0 | Firebase Admin SDK |
| playwright | >=1.40.0,<2.0.0 | ブラウザ自動操作 |

---

## 3. iOS アプリ仕様

### 3.1 基本情報

| 項目 | 値 |
|------|-----|
| **アプリ名** | 物件情報 |
| **Bundle ID** | com.hanawa.realestate.app |
| **対象 OS** | iOS 17.0+ |
| **対象デバイス** | iPhone のみ（iPad 非対応） |
| **デザイン方針** | HIG / OOUI / Liquid Glass（iOS 26）、Material フォールバック（iOS 17-25） |
| **カラーモード** | ライトモードのみ（`.preferredColorScheme(.light)`） |
| **ビルドツール** | XcodeGen（project.yml → .xcodeproj） |
| **Xcode** | 16.0+ |

### 3.2 認証

| 項目 | 仕様 |
|------|------|
| **方式** | Firebase Auth + Google Sign-In |
| **許可ユーザー** | メールアドレスホワイトリスト（`AuthService.allowedEmails`） |
| **フロー** | LoginView → GIDSignIn → Firebase Auth → ホワイトリストチェック → 許可/拒否 |
| **未許可時** | 自動サインアウト + エラー表示 |
| **URL ハンドリング** | `onOpenURL` → `AuthService.handle(url:)` で Google Sign-In コールバック処理 |

#### 許可メールアドレス
- `masaki.hanawa.417@gmail.com`
- `nogura.yuka.kf@gmail.com`

### 3.3 画面構成

#### ナビゲーション構造

```
App起動
├── 認証チェック中 → ProgressView（ローディング）
├── 未認証 → LoginView
│   └── Google サインインボタン
│   └── ウェーブアニメーション背景
└── 認証済み → ContentView
    ├── 初回ログイン → WalkthroughView（7ページ オンボーディング）
    └── TabView（5タブ）
        ├── [0] 中古 → ListingListView(propertyTypeFilter: "chuko")
        ├── [1] 新築 → ListingListView(propertyTypeFilter: "shinchiku")
        ├── [2] 地図 → MapTabView
        ├── [3] お気に入り → ListingListView(favoritesOnly: true)
        └── [4] 設定 → SettingsView
```

#### 3.3.1 ログイン画面（LoginView）

| 要素 | 詳細 |
|------|------|
| **背景** | 青系グラデーション + ウェーブアニメーション（`WaveShape`） |
| **アプリアイコン** | `AppIcon-Login` 画像 |
| **サインインボタン** | Google ブランドガイドライン準拠のボタン |
| **エラー表示** | ホワイトリスト外の場合にエラーメッセージ |

#### 3.3.2 物件一覧画面（ListingListView）

3つのモードで使用:
- **中古タブ**: `propertyTypeFilter: "chuko"`
- **新築タブ**: `propertyTypeFilter: "shinchiku"`
- **お気に入りタブ**: `favoritesOnly: true`

| 機能 | 詳細 |
|------|------|
| **検索** | 物件名でインクリメンタル検索（`.searchable`） |
| **ソート** | 追加日（新しい順）、価格（安い順/高い順）、徒歩（近い順）、広さ（広い順） |
| **フィルタ** | FilterSheet（後述）で条件を指定 |
| **掲載終了フィルタ** | お気に入りタブ: すべて / 掲載中 / 掲載終了 |
| **比較モード** | ツールバーボタンで起動、2〜4件選択 → ComparisonView |
| **CSV エクスポート** | お気に入りタブで ShareLink による CSV 出力 |
| **Pull-to-refresh** | 手動データ更新 |
| **スワイプアクション** | いいね / 詳細表示 |
| **行の表示内容** | 物件名、価格、間取り、面積、徒歩、築年、バッジ（権利形態等） |

#### 3.3.3 フィルタシート（ListingFilterSheet）

| フィルタ項目 | 入力形式 | 詳細 |
|-------------|---------|------|
| **価格** | レンジスライダー | 最小〜最大（万円）、価格未定含むチェック |
| **間取り** | チップ複数選択 | 1K, 1LDK, 2LDK, 3LDK, ... |
| **駅名** | アコーディオン（路線別） | 路線ごとにチップで駅名選択 |
| **駅徒歩** | スライダー | ○分以内 |
| **専有面積** | スライダー | ○㎡以上 |
| **区** | チップ複数選択 | 東京23区 |
| **権利形態** | チェックボックス | 所有権 / 定期借地 |
| **物件種別** | セグメント | すべて / 中古のみ / 新築のみ |

フィルタ状態は `FilterStore`（`@Observable`）で全タブ共有。

#### 3.3.4 物件詳細画面（ListingDetailView）

Sheet として表示。以下のセクションで構成:

| セクション | 内容 |
|-----------|------|
| **掲載終了バナー** | `isDelisted` = true のとき表示 |
| **住所** | 住所テキスト + Google Maps リンク |
| **コメント** | 入力フィールド + コメント一覧（編集・削除可） |
| **内見写真** | PhotoSectionView（撮影・ライブラリ選択・フルスクリーン表示） |
| **物件基本情報** | 価格、間取り、面積、築年、階数/階建て、権利形態、総戸数 |
| **月額支払いシミュレーション** | 中古のみ。ローン条件での月額表示 |
| **通勤時間** | Playground / M3Career への通勤時間（MKDirections）+ Google Maps リンク |
| **住まいサーフィン評価** | 沖式時価、儲かる確率、値上がり率、割安判定、レーダーチャート |
| **値上がりシミュレーション** | 5年/10年の楽観・標準・悲観の3シナリオ + 含み益チャート |
| **ハザード情報** | 洪水、内水、土砂、高潮、津波、液状化 の各リスクレベル |
| **外部リンク** | SUUMO / HOME'S 詳細ページ、住まいサーフィンページ |

#### 3.3.5 地図画面（MapTabView）

| 機能 | 詳細 |
|------|------|
| **地図表示** | MKMapView で全物件をピン表示 |
| **ピン色分け** | 中古（青系）/ 新築（緑系）/ いいね済み（ハート付き） |
| **ピンタップ** | ポップアップ → 物件概要 + いいねボタン → タップで詳細遷移 |
| **フィルタ** | 一覧と共通の FilterStore |
| **現在地ボタン** | 左下ボタンで CLLocationManager → 現在地に移動 |
| **凡例** | 中古 / 新築 / いいね のアイコン凡例 |

##### ハザードマップオーバーレイ

Sheet で表示/非表示を切替。以下のレイヤーを国土地理院 WMS タイルで重畳:

| カテゴリ | レイヤー |
|---------|---------|
| **基本** | 洪水浸水想定、内水浸水想定、土砂災害警戒区域、高潮浸水想定、津波浸水想定、液状化リスク |
| **洪水詳細** | 浸水継続時間、家屋倒壊（氾濫流）、家屋倒壊（河岸侵食） |
| **地盤** | GSI 地盤振動タイル |

##### 東京都地域危険度オーバーレイ

| レイヤー | データソース |
|---------|------------|
| **建物倒壊危険度** | GeoJSON（GitHub raw） → MKPolygon ランク1-5色分け |
| **火災危険度** | 同上 |
| **総合危険度** | 同上 |

#### 3.3.6 設定画面（SettingsView）

| セクション | 項目 |
|-----------|------|
| **通知** | 通知許可設定へのリンク |
| **データ** | フルリフレッシュ、カスタム JSON URL（中古・新築） |
| **スクレイピング** | 条件設定（ScrapingConfigView）、実行ログ（ScrapingLogView） |
| **アカウント** | ユーザー情報表示、サインアウト |
| **ウォークスルー** | オンボーディング再表示 |

#### 3.3.7 物件比較画面（ComparisonView）

- 2〜4件を横並びで比較
- 横スクロールテーブル形式
- 比較項目: 価格、間取り、面積、築年、徒歩、階数、総戸数、権利形態、住まいサーフィン評価

#### 3.3.8 内見写真（PhotoSectionView）

| 機能 | 詳細 |
|------|------|
| **撮影** | CameraCaptureView（UIImagePickerController） |
| **ライブラリ選択** | PhotosPicker（PhotosUI） |
| **サムネイル表示** | PhotoThumbnailView（NSCache でキャッシュ） |
| **フルスクリーン** | PhotoFullscreenView |
| **ローカル保存** | PhotoStorageService → アプリ Documents ディレクトリ |
| **クラウド同期** | PhotoSyncService → Firebase Storage |
| **サイズ制限** | 最大 10MB / 画像ファイルのみ |

#### 3.3.9 オンボーディング（WalkthroughView）

- 7ページ構成
- ページごとにグラデーション背景
- 初回ログイン時に自動表示
- 設定画面から再表示可能

### 3.4 サービス層

#### 3.4.1 ListingStore（物件データ取得・同期）

| 項目 | 詳細 |
|------|------|
| **データソース** | GitHub raw URL の JSON（中古: `latest.json` / 新築: `latest_shinchiku.json`） |
| **デフォルト URL** | `https://raw.githubusercontent.com/masakihnw/real-estate/main/scraping-tool/results/latest.json` |
| **カスタム URL** | 設定画面から変更可能（UserDefaults に保存） |
| **同期方式** | フル置き換え。`identityKey` でマッチして更新/挿入/削除 |
| **ETag キャッシュ** | レスポンスの ETag を保存し、`If-None-Match` で 304 判定 |
| **並列取得** | 中古・新築を `async let` で並列リクエスト |
| **JSON デコード** | `Task.detached(priority: .userInitiated)` でバックグラウンド実行 |
| **新規検出** | 既存の `identityKey` に存在しない物件 → ローカル通知 |
| **自動更新** | フォアグラウンド復帰時に15分経過していれば自動 refresh |

#### 3.4.2 FirebaseSyncService（Firestore 同期）

| 操作 | 詳細 |
|------|------|
| **いいね同期** | `pushLikeState(for:)` → `annotations/{docId}` に `isLiked` を書き込み |
| **コメント追加** | `addComment` → `annotations/{docId}.comments` 配列に追加 |
| **コメント編集** | `editComment` → 該当コメントのテキストを更新 |
| **コメント削除** | `deleteComment` → 該当コメントを配列から除去 |
| **プル同期** | `pullAnnotations(modelContext:)` → 全 annotations を取得しローカル SwiftData に反映 |
| **ドキュメント ID** | SHA256(`identityKey`) の先頭16文字 |

#### 3.4.3 CommuteTimeService（通勤時間計算）

| 項目 | 詳細 |
|------|------|
| **計算方式** | MKDirections（公共交通機関モード） |
| **目的地** | Playground株式会社（千代田区一番町4-6）/ エムスリーキャリア（港区虎ノ門4-1-28） |
| **ジオコーディング** | 物件住所 → CLGeocoder → 座標 |
| **キャッシュ** | `Listing.commuteInfoJSON` に JSON 文字列で保存 |
| **再計算条件** | 未計算 or 7日以上経過 |
| **座標バージョン管理** | 目的地座標変更時に UserDefaults でバージョン管理、全件再計算 |
| **Google Maps 連携** | ディープリンクで Google Maps アプリ（またはブラウザ）を起動 |

#### 3.4.4 通知サービス

| サービス | 種類 | 詳細 |
|---------|------|------|
| **NotificationScheduleService** | ローカル通知 | 新規物件追加時に蓄積 → スケジュール時刻にまとめて配信。新コメント・新写真も通知。 |
| **PushNotificationService** | FCM リモート通知 | トピック `new_listings` を購読。GitHub Actions からスクレイピング後に送信。 |
| **BackgroundRefreshManager** | バックグラウンド更新 | `BGAppRefreshTask` で定期的に JSON 取得 → 新着検出 → ローカル通知 |

#### 3.4.5 その他のサービス

| サービス | 役割 |
|---------|------|
| **NetworkMonitor** | NWPathMonitor でネットワーク接続状態を監視。オフラインバナー表示に使用。 |
| **PhotoStorageService** | ローカルファイルシステムへの写真保存/読込/削除。NSCache でメモリキャッシュ。 |
| **PhotoSyncService** | Firebase Storage への写真アップロード/ダウンロード/削除。 |
| **ScrapingConfigService** | Firestore の `scraping_config/default` からスクレイピング条件を取得/保存。 |
| **ScrapingLogService** | Firestore の `scraping_logs/latest` からパイプラインログを取得。 |
| **SaveErrorHandler** | SwiftData 保存エラーのハンドリング。エラーダイアログ表示。 |

### 3.5 ローンシミュレーション

#### 3.5.1 アプリ独自の計算条件

| パラメータ | 値 |
|-----------|-----|
| **想定価格** | 9,500万円（新築デフォルト） |
| **金利** | 0.8%（変動） |
| **返済期間** | 50年 |
| **頭金** | 0万円 |

#### 3.5.2 住まいサーフィンとの違い

| 項目 | アプリ | 住まいサーフィン |
|------|--------|----------------|
| 想定価格 | 9,500万円 | 6,000万円 |
| 金利 | 0.8% | 0.79% |
| 返済期間 | 50年 | 35年 |

住まいサーフィンからは**変動率（%）のみ**を取り込み、予測価格・ローン残高・含み益はアプリ独自パラメータで再計算。

#### 3.5.3 シミュレーション出力

| 出力 | 内容 |
|------|------|
| **月額返済額** | 元利均等返済の月額 |
| **ローン残高** | 5年後 / 10年後の残債 |
| **予測価格** | 楽観 / 標準 / 悲観 の3シナリオ × 5年後・10年後 |
| **含み益** | 予測価格 − ローン残高（シナリオ別） |
| **シナリオ幅** | ±10ポイント（`scenarioSpreadPP`） |

### 3.6 デザインシステム

#### 3.6.1 DesignSystem.swift

共通のデザイントークンを一元管理:

| トークン | 用途 |
|---------|------|
| **余白** | `listRowVerticalPadding`, `listRowHorizontalPadding` |
| **角丸** | `cornerRadius` |
| **フォントスタイル** | `ListingObjectStyle`（title / subtitle / caption / detailValue / detailLabel） |
| **色** | `shinchikuPriceColor`, `positiveColor`, `negativeColor`, `commutePGColor`, `commuteM3Color`, `cardBackground` |
| **ガラス背景** | `listingGlassBackground()`, `tintedGlassBackground()` |

#### 3.6.2 Liquid Glass 対応

| iOS バージョン | 実装 |
|---------------|------|
| **iOS 26+** | `.glassEffect(in: .rect(cornerRadius:))` で Liquid Glass 適用 |
| **iOS 17-25** | `RoundedRectangle` + `.ultraThinMaterial` でガラス風フォールバック |
| **タブバー** | iOS 26 ではシステムが自動で Liquid Glass を適用 |

#### 3.6.3 アセットカタログ

| アセット | 用途 |
|---------|------|
| `AppIcon` | アプリアイコン |
| `AppIcon-Login` | ログイン画面用アイコン |
| `AccentColor` | アクセントカラー |
| `tab-chuko`, `tab-shinchiku`, `tab-map`, `tab-favorites`, `tab-settings` | タブアイコン |
| `icon-hazard` | ハザードアイコン |
| `logo-m3career`, `logo-playground` | 通勤バッジロゴ |

---

## 4. スクレイピングツール仕様

### 4.1 データソース

| ソース | 種別 | URL パターン |
|--------|------|-------------|
| **SUUMO 中古** | 中古マンション | `suumo.jp/ms/chuko/tokyo/sc_{ward}/` |
| **HOME'S 中古** | 中古マンション | `homes.co.jp/mansion/chuko/tokyo/23ku/list/` |
| **SUUMO 新築** | 新築マンション | `suumo.jp/jj/bukken/ichiran/JJ011FC001/?ar=030&bs=010&ta=13` |
| **HOME'S 新築** | 新築マンション | `homes.co.jp/mansion/shinchiku/tokyo/list/` |
| **住まいサーフィン** | 評価データ | `sumai-surfin.com`（ログイン必要） |
| **国土地理院** | ハザードデータ | GSI タイル（`disaportaldata.gsi.go.jp`） |
| **東京都** | 地域危険度 | GeoJSON（GitHub raw） |

### 4.2 スクレイピングパイプライン

```
1. main.py（スクレイピング実行）
   ├── suumo_scraper.py       → SUUMO 中古物件取得
   ├── homes_scraper.py       → HOME'S 中古物件取得
   ├── suumo_shinchiku_scraper.py → SUUMO 新築物件取得
   └── homes_shinchiku_scraper.py → HOME'S 新築物件取得
       ↓ フィルタ・重複除去
2. results/latest.json, results/latest_shinchiku.json 出力
       ↓
3. エンリッチメント（update_listings.sh 内で順次実行）
   ├── embed_geocode.py       → ジオコーディング（住所→座標）
   ├── hazard_enricher.py     → ハザード情報付与
   ├── sumai_surfin_enricher.py → 住まいサーフィン評価付与
   └── commute_enricher.py    → 通勤時間付与
       ↓
4. generate_report.py → Markdown レポート生成
5. check_changes.py   → 前回との差分チェック
6. slack_notify.py    → Slack 通知（変更ありの場合）
7. send_push.py       → FCM プッシュ通知（新着ありの場合）
8. upload_scraping_log.py → Firestore にログ保存
```

### 4.3 スクレイパー詳細

#### 4.3.1 SUUMO 中古（suumo_scraper.py）

| 項目 | 詳細 |
|------|------|
| **パース対象** | `div.property_unit-content` / カセットレイアウト |
| **取得フィールド** | name, price, address, station_line, walk_min, area_m2, layout, built_year, floor, ownership |
| **総戸数** | `building_units.json`（詳細ページキャッシュ）から取得 |
| **出力** | `SuumoListing` dataclass |

#### 4.3.2 HOME'S 中古（homes_scraper.py）

| 項目 | 詳細 |
|------|------|
| **パース対象** | JSON-LD + HTML（`mod-mergeBuilding`, `mod-listKks`） |
| **WAF 対策** | AWS WAF 検知機能（`is_waf_challenge`）、長めのリクエスト間隔（5秒） |
| **出力** | `HomesListing` dataclass |

#### 4.3.3 SUUMO 新築（suumo_shinchiku_scraper.py）

| 項目 | 詳細 |
|------|------|
| **取得フィールド** | 基本情報 + 価格レンジ、面積レンジ、間取りレンジ、引渡時期 |
| **出力** | `SuumoShinchikuListing` dataclass |

#### 4.3.4 HOME'S 新築（homes_shinchiku_scraper.py）

| 項目 | 詳細 |
|------|------|
| **パース対象** | JSON-LD + カード形式 HTML |
| **出力** | `HomesShinchikuListing` dataclass |

### 4.4 フィルタ・重複除去

#### フィルタ条件（`apply_conditions`）

各スクレイパーの結果に対して以下の条件でフィルタ:

- 東京23区以内
- 価格: `PRICE_MIN_MAN`〜`PRICE_MAX_MAN`
- 面積: `AREA_MIN_M2` 以上
- 間取り: `LAYOUT_PREFIX_OK` に前方一致
- 築年: `BUILT_YEAR_MIN` 以降
- 徒歩: `WALK_MIN_MAX` 以内
- 総戸数: `TOTAL_UNITS_MIN` 以上
- 路線: `ALLOWED_LINE_KEYWORDS` のいずれかを含む
- 駅乗降客数: `STATION_PASSENGERS_MIN` 以上（0 = フィルタなし）

#### 重複除去（`dedupe_listings`）

`listing_key` = (name, layout, area, price, address, built_year, station_line, walk_min) の組み合わせで一意化。重複件数は `duplicate_count` に記録。

### 4.5 エンリッチャー

#### 4.5.1 通勤時間エンリッチャー（commute_enricher.py）

| 項目 | 詳細 |
|------|------|
| **データソース** | `data/commute_playground.json`, `data/commute_m3career.json`（駅名→所要時間マップ） |
| **計算式** | `walk_min × 1.2（補正係数）+ 電車所要時間` |
| **複数駅対応** | 全駅について計算し最短を採用 |
| **未登録駅** | フォールバック 30分 + オフィス徒歩（PG: 5分, M3: 7分） |

#### 4.5.2 ハザードエンリッチャー（hazard_enricher.py）

国土地理院タイルと東京都地域危険度 GeoJSON から以下を付与:

- 洪水浸水深、内水浸水深、土砂災害警戒、高潮浸水深、津波浸水深
- 液状化リスク
- 建物倒壊危険度、火災危険度、総合危険度

#### 4.5.3 住まいサーフィンエンリッチャー（sumai_surfin_enricher.py）

| 項目 | 詳細 |
|------|------|
| **認証** | `SUMAI_USER` / `SUMAI_PASS` 環境変数 |
| **ブラウザ自動操作** | Playwright（`sumai_surfin_browser.py`） |
| **取得データ** | 沖式時価、儲かる確率、値上がり率、レーダーチャート、割安判定、ランキング等 |

### 4.6 通勤時間ツール

| ファイル | 用途 |
|---------|------|
| **commute.py** | コアロジック: 駅名パース、通勤時間計算、表示文字列生成 |
| **commute_audit.py** | 手動監査用 HTML 生成（Google Maps との比較） |
| **commute_auto_audit.py** | Playwright 自動監査（Google Maps に到着 8:30 で経路検索 → 所要時間を抽出） |

### 4.7 分析・予測

| ファイル | 機能 |
|---------|------|
| **price_predictor.py** | `MansionPricePredictor`：CSV データに基づく価格予測 |
| **asset_score.py** | 資産ランク S/A/B/C の算出（含み益率ベース） |
| **asset_simulation.py** | 10年シミュレーション |
| **future_estate_predictor.py** | 10年価格予測（3シナリオ） |
| **loan_calc.py** | 50年ローン月額返済額計算 |

### 4.8 レポート生成

`generate_report.py` が以下のレポートを Markdown で生成:

| セクション | 内容 |
|-----------|------|
| **新着物件** | 前回から追加された物件 |
| **価格変更** | 前回から価格が変わった物件 |
| **掲載終了** | 前回から消えた物件 |
| **区別一覧** | 区ごとの物件リスト |
| **駅別一覧** | 駅ごとの物件リスト |
| **オプション** | 資産ランク、通勤時間、ローン情報（有効な場合） |

### 4.9 出力ファイル

| ファイル | 形式 | 内容 |
|---------|------|------|
| `results/latest.json` | JSON | 中古マンション物件リスト |
| `results/latest_shinchiku.json` | JSON | 新築マンション物件リスト |
| `results/report/report.md` | Markdown | 差分レポート |
| `results/map_viewer.html` | HTML | 地図ビューア |
| `data/commute_playground.json` | JSON | Playground 通勤時間マスター |
| `data/commute_m3career.json` | JSON | M3Career 通勤時間マスター |
| `data/geocode_cache.json` | JSON | ジオコーディングキャッシュ |
| `data/building_units.json` | JSON | 総戸数キャッシュ |

---

## 5. データモデル

### 5.1 Listing（SwiftData @Model）

iOS アプリのメインデータモデル。`scraping-tool/results/latest.json` / `latest_shinchiku.json` の1件に対応。

#### 基本情報

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `source` | String? | データソース（"suumo", "homes"） |
| `url` | String | 物件詳細ページ URL |
| `name` | String | 物件名 |
| `priceMan` | Int? | 価格（万円） |
| `address` | String? | 住所 |
| `stationLine` | String? | 最寄り路線・駅名 |
| `walkMin` | Int? | 駅徒歩（分） |
| `areaM2` | Double? | 専有面積（㎡） |
| `layout` | String? | 間取り（例: "3LDK"） |
| `builtStr` | String? | 築年月（文字列） |
| `builtYear` | Int? | 築年（西暦） |
| `totalUnits` | Int? | 総戸数 |
| `floorPosition` | Int? | 所在階 |
| `floorTotal` | Int? | 階建て |
| `floorStructure` | String? | 構造（例: "RC"） |
| `ownership` | String? | 権利形態 |
| `listWardRoman` | String? | 区（ローマ字） |
| `fetchedAt` | Date | 取得日時 |
| `addedAt` | Date | 初回追加日時（同期で上書きしない） |

#### ユーザーデータ

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `memo` | String? | メモ（レガシー、コメントに移行済み） |
| `isLiked` | Bool | いいね状態 |
| `commentsJSON` | String? | コメント JSON（Firestore 同期） |
| `isDelisted` | Bool | 掲載終了フラグ |
| `photosJSON` | String? | 内見写真メタデータ JSON |

#### 新築固有フィールド

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `propertyType` | String | "chuko" or "shinchiku" |
| `priceMaxMan` | Int? | 価格帯上限（万円） |
| `areaMaxM2` | Double? | 面積幅上限（㎡） |
| `deliveryDate` | String? | 引渡時期 |

#### 位置情報

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `latitude` | Double? | 緯度 |
| `longitude` | Double? | 経度 |
| `duplicateCount` | Int | 重複集約数 |

#### 住まいサーフィン評価データ

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `ssProfitPct` | Int? | 沖式儲かる確率 (%) |
| `ssOkiPrice70m2` | Int? | 沖式中古時価（万円, 70㎡換算） |
| `ssM2Discount` | Int? | m²割安額（万円/㎡）、負値=割安 |
| `ssValueJudgment` | String? | 割安判定（"割安"/"適正"/"割高"） |
| `ssStationRank` | String? | 駅ランキング |
| `ssWardRank` | String? | 区ランキング |
| `ssSumaiSurfinURL` | String? | 住まいサーフィンページ URL |
| `ssAppreciationRate` | Double? | 中古値上がり率 (%) |
| `ssFavoriteCount` | Int? | お気に入りランキングスコア |
| `ssPurchaseJudgment` | String? | 購入判定 |
| `ssRadarData` | String? | レーダーチャート偏差値 JSON |

#### シミュレーションデータ

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `ssSimBest5yr` / `ssSimBest10yr` | Int? | 楽観シナリオ予測価格（万円） |
| `ssSimStandard5yr` / `ssSimStandard10yr` | Int? | 標準シナリオ予測価格 |
| `ssSimWorst5yr` / `ssSimWorst10yr` | Int? | 悲観シナリオ予測価格 |
| `ssLoanBalance5yr` / `ssLoanBalance10yr` | Int? | ローン残高 |
| `ssSimBasePrice` | Int? | シミュレーション基準価格 |
| `ssNewM2Price` | Int? | 新築㎡単価 |
| `ssForecastM2Price` | Int? | 予測㎡単価 |
| `ssForecastChangeRate` | Double? | 予測変動率 |
| `ssPastMarketTrends` | String? | 過去の市場動向 JSON |
| `ssSurroundingProperties` | String? | 周辺物件 JSON |
| `ssPriceJudgments` | String? | 価格判定 JSON |

#### ハザード・通勤

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `hazardInfo` | String? | ハザード情報 JSON |
| `commuteInfoJSON` | String? | 通勤時間情報 JSON |

### 5.2 ListingFilter

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `priceMin` | Int? | 最低価格（万円） |
| `priceMax` | Int? | 最高価格（万円） |
| `includePriceUndecided` | Bool | 価格未定を含む |
| `layouts` | [String] | 間取りフィルタ |
| `wards` | [String] | 区フィルタ |
| `walkMax` | Int? | 徒歩上限（分） |
| `areaMin` | Double? | 面積下限（㎡） |
| `ownershipTypes` | [OwnershipType] | 権利形態フィルタ |
| `propertyType` | PropertyTypeFilter | 物件種別フィルタ |

### 5.3 CommentData

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `id` | String | コメント ID（UUID） |
| `text` | String | コメント本文 |
| `authorName` | String | 投稿者名 |
| `authorId` | String | 投稿者 ID（Firebase UID） |
| `createdAt` | String | 作成日時（ISO 8601） |

### 5.4 ScrapingConfig

Firestore で共有されるスクレイピング条件:

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `priceMinMan` | Int | 最低価格（万円） |
| `priceMaxMan` | Int | 最高価格（万円） |
| `areaMinM2` | Double | 最低面積（㎡） |
| `areaMaxM2` | Double? | 最高面積（㎡） |
| `walkMinMax` | Int | 徒歩上限（分） |
| `builtYearMin` | Int | 最低築年 |
| `totalUnitsMin` | Int | 最低総戸数 |
| `layoutPrefixOk` | [String] | 間取りプレフィックス |
| `allowedLineKeywords` | [String] | 路線キーワード |

### 5.5 キー定義

| キー名 | 構成要素 | 用途 |
|--------|---------|------|
| **identity_key** | name + layout + area_m2 + address + built_year + station_line + walk_min | 同一物件の判定（**価格を含まない**） |
| **listing_key** | name + layout + area_m2 + price + address + built_year + station_line + walk_min | 重複除去（**価格を含む**） |

---

## 6. Firebase 仕様

### 6.1 Firestore コレクション

#### annotations（ユーザーデータ）

| フィールド | 型 | 説明 |
|-----------|-----|------|
| **ドキュメントID** | String | SHA256(identityKey) 先頭16文字 |
| `isLiked` | Boolean | いいね状態 |
| `comments` | Array | コメント配列（CommentData 形式） |
| `photos` | Array | 写真メタデータ配列 |

#### scraping_config（スクレイピング条件）

| ドキュメント | 内容 |
|------------|------|
| `default` | ScrapingConfig の全フィールド |

#### scraping_logs（実行ログ）

| ドキュメント | 内容 |
|------------|------|
| `latest` | 最新のスクレイピングパイプライン実行ログ |

### 6.2 Firestore セキュリティルール

```
annotations/{docId}        → 認証済みユーザーのみ読み書き
scraping_config/{docId}    → 認証済みユーザーのみ読み書き
```

GitHub Actions のサービスアカウント（Firebase Admin SDK）はルールの制約を受けない。

### 6.3 Firebase Storage ルール

```
photos/{docId}/{photoId}   → 認証済みユーザーのみ読み書き
                              サイズ上限: 10MB
                              コンテンツタイプ: image/*
```

### 6.4 Firebase Cloud Messaging

| 項目 | 詳細 |
|------|------|
| **トピック** | `new_listings` |
| **送信元** | GitHub Actions（`send_push.py`）→ FCM HTTP v1 API |
| **受信** | iOS アプリ（`PushNotificationService` / `AppDelegate`） |
| **トリガー** | スクレイピングで新着物件検出時 |

---

## 7. CI/CD パイプライン

### 7.1 GitHub Actions ワークフロー

**ファイル**: `.github/workflows/update-listings.yml`

#### トリガー

| トリガー | 条件 |
|---------|------|
| **スケジュール** | 2時間ごと + 毎日 21:30 UTC（6:30 JST、Slack 通知つき） |
| **手動実行** | `workflow_dispatch`（`send_slack` パラメータ入力可） |

#### ジョブフロー

```
1. actions/checkout
2. actions/setup-python@v5 (Python 3.9)
3. pip install -r scraping-tool/requirements.txt
4. scripts/update_listings.sh --no-git
   ├── main.py（スクレイピング）
   ├── embed_geocode.py（ジオコーディング）
   ├── hazard_enricher.py（ハザード情報）
   ├── sumai_surfin_enricher.py（住まいサーフィン）
   ├── commute_enricher.py（通勤時間）
   ├── generate_report.py（レポート生成）
   └── check_changes.py（差分チェック）
5. upload_scraping_log.py（実行ログ → Firestore）
6. 変更あり → slack_notify.py（Slack 通知）
7. 変更あり → send_push.py（FCM プッシュ通知）
8. 変更あり → git commit & push
```

#### 必要なシークレット

| シークレット | 用途 |
|------------|------|
| `SUMAI_USER` | 住まいサーフィン ユーザー名 |
| `SUMAI_PASS` | 住まいサーフィン パスワード |
| `FIREBASE_SERVICE_ACCOUNT` | Firebase サービスアカウント JSON 文字列 |
| `SLACK_WEBHOOK_URL` | Slack Webhook URL |
| `GITHUB_TOKEN` | リポジトリ Read and Write 権限 |

---

## 8. 購入条件・フィルタロジック

### 8.1 スクレイピング検索条件（config.py）

| 条件 | 値 | 根拠 |
|------|-----|------|
| **エリア** | 東京23区 | — |
| **価格** | 7,500万〜1億円 | 住み替え前提の投資判断 |
| **面積** | 60㎡以上（上限なし） | 需要の厚いゾーン |
| **間取り** | 2LDK / 3LDK（プレフィックス "2", "3"） | 買い手母集団が厚い |
| **築年** | 実行年 − 20年以降 | 新耐震 + 築浅優先 |
| **駅徒歩** | 7分以内 | ドラフト条件の厳格化 |
| **総戸数** | 50戸以上 | 管理安定性・流動性 |
| **路線** | JR / 東京メトロ / 都営 / 主要私鉄 | 需要の厚い路線に限定 |
| **リクエスト間隔** | SUUMO: 2秒 / HOME'S: 5秒 | 負荷軽減・WAF 対策 |
| **タイムアウト** | 60秒 / リトライ3回 | 安定性確保 |

### 8.2 Firestore 経由の条件上書き

`scraping_config/default` に保存された条件は、`firestore_config_loader.py` が `FIREBASE_SERVICE_ACCOUNT` 環境変数の存在時に自動的に `config` モジュールをパッチする。iOS アプリの設定画面から条件を変更可能。

### 8.3 購入判断フロー

```
1. 物件候補を20件拾う（駅徒歩/広さ/築年で一次フィルタ）
2. 管理計画認定の有無を必須で確認（対象外は候補から外す）
3. 管理書類で10件に絞る（長期修繕計画・積立・修繕履歴）
4. REINS 成約データで「売れる速度」「価格推移」を見て最終3件
5. 3件のみ内見（現地で売却時の説明コストになる瑕疵を潰す）
```

---

## 9. 非機能要件

### 9.1 パフォーマンス

| 処理 | 最適化手法 |
|------|-----------|
| **データ取得** | 中古/新築を `async let` で並列 HTTP リクエスト |
| **JSON デコード** | `Task.detached(priority: .userInitiated)` でバックグラウンド |
| **DB 同期** | `identityKey → Listing` の Dictionary で O(1) ルックアップ |
| **GeoJSON デコード** | バックグラウンドスレッド |
| **DateFormatter** | `static let` で使い回し |
| **二重更新防止** | `guard !isRefreshing` でガード |
| **ETag** | 304 Not Modified でダウンロードスキップ |
| **リスト行** | テキストと SF Symbol のみ（画像なし、軽量レンダリング） |

### 9.2 オフライン動作

| 画面 | オフライン時の挙動 |
|------|-------------------|
| **一覧（中古/新築）** | SwiftData キャッシュから表示。更新はエラー表示。 |
| **お気に入り** | ローカルから表示。Firestore 同期は次回オンライン時。 |
| **地図** | キャッシュ済みピン表示。未キャッシュのハザードタイルは非表示。 |
| **設定** | 全項目表示可能。フルリフレッシュはエラー。 |
| **詳細** | ローカルデータ表示。外部リンクはブラウザがオフラインエラー。 |
| **通勤時間** | MKDirections はオフライン不可。キャッシュ済み結果は表示。 |

### 9.3 アクセシビリティ

| 項目 | 対応 |
|------|------|
| **Dynamic Type** | 全画面でシステムフォントスタイル使用、ハードコードサイズなし |
| **VoiceOver** | 一覧行に `accessibilityLabel`（物件名・価格・面積・徒歩）を設定 |
| **色のコントラスト** | セマンティックカラー使用、ライト/ダークモードで自動調整 |
| **タップターゲット** | 最小 44pt |
| **操作ヒント** | `accessibilityHint`（「タップで詳細。ハートでいいね」） |

### 9.4 セキュリティ

| 項目 | 対応 |
|------|------|
| **認証** | Google サインイン + メールホワイトリスト |
| **Firestore** | 認証済みユーザーのみ読み書き |
| **Storage** | 認証済みユーザーのみ、10MB/画像のみ制限 |
| **Admin SDK** | サービスアカウントは Firestore ルールの制約を受けない |
| **環境変数** | シークレットは GitHub Actions Secrets で管理、`.env` は `.gitignore` |

---

## 10. 用語集

| 用語 | 定義 |
|------|------|
| **listing** | 物件1件のデータ |
| **identity_key** | 名前・間取り・面積・住所・築年・路線・徒歩で一意化するキー（価格を含まない） |
| **listing_key** | identity_key + 価格。重複除去に使用 |
| **annotation** | いいね・コメント・写真のユーザーデータ。Firebase Firestore で家族間共有 |
| **property_type** | `"chuko"`（中古）または `"shinchiku"`（新築） |
| **hazard overlay** | 国土地理院のハザードマップタイルを地図に重畳表示するレイヤー |
| **enricher** | スクレイピング後にデータを付加するスクリプト群（通勤・ハザード・住まいサーフィン） |
| **identity_key → docId** | SHA256(identity_key) の先頭16文字。Firestore のドキュメント ID |
| **ETag** | HTTP キャッシュ制御ヘッダー。304 Not Modified でダウンロードをスキップ |
| **Liquid Glass** | iOS 26 のデザインシステム。半透明のガラス質感 |
| **OOUI** | Object-Oriented User Interface。オブジェクト中心の UI 設計 |
| **HIG** | Human Interface Guidelines。Apple のデザインガイドライン |
| **沖式** | 住まいサーフィンの不動産評価指標。時価算出・儲かる確率等 |
| **REINS** | Real Estate Information Network System。不動産流通標準情報システム |
| **FCM** | Firebase Cloud Messaging。リモートプッシュ通知サービス |

---

## 付録 A: 環境変数一覧

| 変数名 | 用途 | 使用場所 |
|--------|------|----------|
| `SUMAI_USER` | 住まいサーフィン ユーザー名 | GitHub Actions, sumai_surfin_enricher.py |
| `SUMAI_PASS` | 住まいサーフィン パスワード | GitHub Actions, sumai_surfin_enricher.py |
| `FIREBASE_SERVICE_ACCOUNT` | Firebase サービスアカウント JSON | GitHub Actions, firestore_config_loader.py, upload_scraping_log.py, send_push.py |
| `FIREBASE_PROJECT_ID` | FCM フォールバック | send_push.py |
| `SLACK_WEBHOOK_URL` | Slack Webhook URL | GitHub Actions, slack_notify.py |

---

## 付録 B: ドキュメント相互参照

| ファイル | 内容 |
|---------|------|
| `docs/SPECIFICATION.md` | **本ファイル**（総合仕様書） |
| `docs/10year-index-mansion-conditions-draft.md` | 購入条件ドラフト |
| `docs/initial-consultation.md` | 初回相談メモ |
| `real-estate-ios/docs/REQUIREMENTS.md` | iOS アプリ要件定義 |
| `real-estate-ios/docs/DB-STRATEGY.md` | DB 設計方針 |
| `real-estate-ios/docs/DESIGN.md` | デザイン指針 |
| `real-estate-ios/docs/FIREBASE-SETUP.md` | Firebase セットアップ手順 |
| `real-estate-ios/docs/TODO.md` | 未確定事項・TODO |
| `scraping-tool/README.md` | スクレイピングツール詳細 |
| `scraping-tool/docs/GITHUB_SETUP.md` | GitHub Actions セットアップ |
| `scraping-tool/docs/SLACK_SETUP.md` | Slack 通知セットアップ |

---

## 付録 C: JSON データフォーマット

### C.1 中古マンション（latest.json）

```json
[
  {
    "source": "suumo",
    "url": "https://suumo.jp/...",
    "name": "○○マンション",
    "price_man": 8500,
    "address": "東京都○○区...",
    "station_line": "東京メトロ○○線 ○○駅",
    "walk_min": 5,
    "area_m2": 65.0,
    "layout": "3LDK",
    "built_year": 2010,
    "built_str": "2010年3月",
    "total_units": 120,
    "floor_position": 8,
    "floor_total": 15,
    "floor_structure": "RC",
    "ownership": "所有権",
    "list_ward_roman": "minato",
    "property_type": "chuko",
    "latitude": 35.6580,
    "longitude": 139.7513,
    "duplicate_count": 1,
    "ss_profit_pct": 85,
    "ss_oki_price_70m2": 9200,
    "ss_value_judgment": "割安",
    "ss_appreciation_rate": 12.5,
    "ss_radar_data": "{...}",
    "hazard_info": "{...}",
    "commute_info": "{...}"
  }
]
```

### C.2 新築マンション（latest_shinchiku.json）

```json
[
  {
    "source": "suumo",
    "url": "https://suumo.jp/...",
    "name": "○○レジデンス",
    "price_man": 7800,
    "price_max_man": 9500,
    "address": "東京都○○区...",
    "station_line": "JR○○線 ○○駅",
    "walk_min": 3,
    "area_m2": 60.0,
    "area_max_m2": 75.0,
    "layout": "2LDK~3LDK",
    "delivery_date": "2027年9月上旬予定",
    "total_units": 200,
    "list_ward_roman": "shibuya",
    "property_type": "shinchiku",
    "latitude": 35.6600,
    "longitude": 139.7000
  }
]
```

### C.3 コメントデータ（commentsJSON）

```json
[
  {
    "id": "uuid-string",
    "text": "内見メモ：日当たり良好",
    "authorName": "Masaki",
    "authorId": "firebase-uid",
    "createdAt": "2025-01-15T10:30:00Z"
  }
]
```

### C.4 通勤時間データ（commuteInfoJSON）

```json
{
  "destinations": [
    {
      "name": "Playground株式会社",
      "minutes": 25,
      "calculatedAt": "2025-01-15T10:00:00Z"
    },
    {
      "name": "エムスリーキャリア",
      "minutes": 30,
      "calculatedAt": "2025-01-15T10:00:00Z"
    }
  ]
}
```
