# 物件情報アプリ 総合仕様書

> **最終更新**: 2026-10-02（文章の見直しと、1章から3章のうちコードで確認できた記述の修正。iOS ビルド番号は `project.yml` の `CURRENT_PROJECT_VERSION` が正で、この時点は 836）
> **ステータス**: 運用中  
> **リポジトリ**: https://github.com/masakihnw/real-estate

---

## 目次

1. [プロジェクト概要](#1-プロジェクト概要)
2. [システムアーキテクチャ](#2-システムアーキテクチャ)
3. [iOS アプリ仕様](#3-ios-アプリ仕様)
4. [画面別機能一覧](#4-画面別機能一覧)
5. [スクレイピングツール仕様](#5-スクレイピングツール仕様)
6. [データモデル](#6-データモデル)
7. [Firebase 仕様](#7-firebase-仕様)
8. [CI/CD パイプライン](#8-cicd-パイプライン)
9. [購入条件・フィルタロジック](#9-購入条件フィルタロジック)
10. [非機能要件](#10-非機能要件)
11. [用語集](#11-用語集)

---

## 1. プロジェクト概要

### 1.1 目的

10年住み替え前提で、インデックス投資（年5%）を上回る中古マンションを購入するためのツール群。複数の不動産サイトから物件情報を自動スクレイピングし、iOS アプリで閲覧・比較・評価する。取得元は `scraping-tool/` の `suumo_scraper.py`、`homes_scraper.py`、`rehouse_scraper.py`、`nomucom_scraper.py`、`athome_scraper.py`、`stepon_scraper.py`、`livable_scraper.py` の7サイト。iOS アプリは新築マンションを表示せず、中古のみを扱う（`SupabaseListingStore.purgeNonChukoListings` が中古以外を端末から削除する）。

### 1.2 ターゲットユーザー

- 自分自身と家族（妻）
- TestFlight で限定配布する
- Google サインインのメールアドレスホワイトリストで利用者を制限する

### 1.3 プロジェクト構成

```
real-estate/
├── .github/workflows/         # CI/CD（GitHub Actions）
├── docs/                      # 購入条件・相談メモ・本仕様書
├── firebase.json              # Firebase 設定
├── firestore.rules            # Firestore セキュリティルール
├── storage.rules              # Firebase Storage ルール
├── supabase/migrations/       # Supabase スキーマ（3桁連番）
├── configs/                   # 通勤先などの設定
├── data/                      # 通勤駅マスターの雛形とサンプルデータ
├── scripts/                   # Firestore から Supabase への移行スクリプト
├── design/                    # iOS デザインシステム
├── ref/                       # 購入検討の参考資料
├── real-estate-ios/           # iOS アプリ（SwiftUI + SwiftData）
│   ├── RealEstateApp/         # アプリ本体ソースコード（ScrapingConfigMetadata.json を含む）
│   ├── RealEstateAppTests/    # ユニットテスト
│   ├── RealEstateWidget/      # WidgetKit ホーム画面ウィジェット拡張
│   ├── scripts/               # deploy.sh、verify_required_resources.sh
│   ├── docs/                  # iOS アプリ設計ドキュメント
│   └── project.yml            # XcodeGen 設定
└── scraping-tool/             # Python スクレイピングパイプライン
    ├── scripts/               # シェルスクリプト（run_scrape.sh, run_enrich.sh, run_finalize.sh 等）
    ├── config/                # 買い手プロフィール、購入戦略、AI プロンプト
    ├── data/                  # キャッシュ・マスターデータ
    ├── results/               # 出力（latest.json 等）
    ├── docs/                  # セットアップ・技術ドキュメント
    └── tests/                 # pytest テスト
```

---

## 2. システムアーキテクチャ

### 2.1 全体構成図

```
┌────────────────────────────────────────────────────────────────────┐
│                    GitHub Actions（CI/CD）                          │
│  main.py → enrichers → sync_db.py → generate_report.py             │
│  → send_push.py → upload_scraping_log.py → slack_notify.py         │
└────────────────────┬───────────────────────────────────────────────┘
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
┌──────────┐  ┌───────────┐  ┌──────────────┐
│ Supabase │  │ Firebase  │  │ Slack        │
│ (DB)     │  │ (BaaS)    │  │ (Webhook)    │
└────┬─────┘  └─────┬─────┘  └──────────────┘
     │              │
     │    ┌─────────┴──────────────────────┐
     │    │ Firestore  : scraping_logs,    │
     │    │              写真メタデータ      │
     │    │ Auth       : Google Sign-In     │
     │    │ Storage    : 内見写真            │
     │    │ FCM        : プッシュ通知        │
     │    └─────────────────────────────────┘
     │              │
     ▼              ▼
┌────────────────────────────────────────────────────────────────────┐
│                  iOS アプリ（SwiftUI + SwiftData）                   │
│  ListingStore / SupabaseListingStore → SwiftData → UI              │
│  SupabaseAnnotationService ↔ Supabase（いいね・コメント）            │
│  PhotoSyncService ↔ Firebase Storage                               │
│  CommuteTimeService → MKDirections                                 │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 技術スタック

| レイヤー | 技術 |
|---------|------|
| **iOS アプリ** | SwiftUI, SwiftData, MapKit, CoreLocation, PhotosUI, SafariServices, CoreSpotlight |
| **認証** | Firebase Auth + Google Sign-In |
| **データ同期** | Supabase（物件・いいね・コメント）、Firebase Firestore（スクレイピングログ・写真メタデータ）、Firebase Storage（内見写真） |
| **通知** | Firebase Cloud Messaging (FCM) + ローカル通知 |
| **スクレイピング** | Python 3.11, requests, BeautifulSoup4, lxml, Playwright |
| **データ配信** | Supabase API（既定）。カスタム URL を設定した場合のみ JSON を直接取得 |
| **CI/CD** | GitHub Actions |
| **通知（開発者向け）** | Slack Webhook |
| **ビルド管理** | XcodeGen (project.yml) |

### 2.3 依存パッケージ

#### iOS（Swift Package Manager）

| パッケージ | バージョン | 用途 |
|-----------|-----------|------|
| Firebase | 12.9.0 | Auth, Firestore, Messaging, Storage, Crashlytics |
| GoogleSignIn | 8.0.0 | Google サインイン |

SupabaseはSDKを使わない。`SupabaseClient.swift` がURLSessionでREST API（PostgREST）を呼ぶ。

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
| PyYAML | >=6.0.0,<7.0.0 | YAML 読み込み |
| supabase | >=2.0.0,<3.0.0 | Supabase 同期（`supabase_sync.py`） |
| boto3 | >=1.34.0,<2.0.0 | Cloudflare R2 への画像保存（`image_storage.py`） |
| anthropic | >=0.40.0,<1.0.0 | Claude API（名寄せ・画像分類・テキスト抽出・サマリー生成） |

---

## 3. iOS アプリ仕様

### 3.1 基本情報

| 項目 | 値 |
|------|-----|
| **アプリ名** | 物件情報 |
| **Bundle ID** | com.hanawa.realestate.app |
| **対象 OS** | iOS 17.0+ |
| **対象デバイス** | iPhone / iPad（Mac Catalyst は廃止済みで、`project.yml` で `SUPPORTS_MACCATALYST: "NO"`） |
| **デザイン方針** | HIG / OOUI / Liquid Glass（iOS 26）、Material フォールバック（iOS 17-25） |
| **カラーモード** | ライトモードのみ（`.preferredColorScheme(.light)`） |
| **ビルドツール** | XcodeGen（project.yml → .xcodeproj） |
| **Xcode** | 16.0+ |

### 3.2 認証

| 項目 | 仕様 |
|------|------|
| **方式** | Firebase Auth + Google Sign-In |
| **許可ユーザー** | メールアドレスのホワイトリスト。実値は gitignore 対象の `AllowedEmails.plist` に置き、リポジトリには記載しない。ファイルがない場合は許可リストが空になり、全員が拒否される |
| **フロー** | LoginView → GIDSignIn → Firebase Auth → ホワイトリストチェック → 許可/拒否 |
| **未許可時** | 自動サインアウト + エラー表示 |
| **URL ハンドリング** | `onOpenURL` から `AuthService.handle(_:)` を呼び、Google Sign-In のコールバックを処理する |

### 3.3 画面構成

#### ナビゲーション構造

`@Environment(\.horizontalSizeClass)` でレイアウトを切り替えるアダプティブ構成にしている。

- **compact（iPhone）**: TabView でタブを切り替える
- **regular（iPad）**: NavigationSplitView によるサイドバー＋詳細の2カラム構成

```
App起動
├── 認証チェック中 → ProgressView（ローディング）
├── 未認証 → LoginView
│   └── Google サインインボタン
│   └── ウェーブアニメーション背景
└── 認証済み → ContentView
    ├── 初回ログイン → WalkthroughView（7ページ オンボーディング）
    │
    ├── [compact] TabView（4タブ）
    │   ├── [0] 今日 → TodayView
    │   │   └── 「すべての動き」→ ActivityFeedView
    │   ├── [1] さがす → BrowseTabView
    │   │   └── セグメントピッカー [リスト | 地図]
    │   │       ├── リスト → PropertyListingTabView → ListingListView(propertyTypeFilter: "chuko")
    │   │       └── 地図 → MapTabView
    │   ├── [2] マイリスト → ListingListView(favoritesOnly: true)
    │   └── [3] 設定 → SettingsView
    │       └── 成約事例 → TransactionTabView（シート表示）
    │           └── セグメントピッカー [一覧 | 地図]
    │               ├── 一覧 → TransactionListView（建物グループ折りたたみ式、タップで TransactionDetailView）
    │               │       └── TransactionDetailView（取引詳細 + 類似条件 m²単価推移チャート）
    │               └── 地図 → TransactionMapView（1物件=1ピン、タップで BuildingGroupDetailView）
    │
    └── [regular] NavigationSplitView
        ├── Sidebar: SidebarItem（今日/さがす/マイリスト/設定）
        └── Detail: 選択されたセクションのビュー
```

旧構成の概況タブ（DashboardView）と成約タブは廃止した。概況は今日タブ（TodayView）に置き換え、成約事例は設定画面から開く。

#### SidebarItem（iPad 用サイドバー項目）

| 項目 | アイコン | 対応ビュー |
|------|---------|-----------|
| 今日 | `sun.max` | TodayView |
| さがす | `magnifyingglass` | BrowseTabView |
| マイリスト | `heart` | ListingListView(favoritesOnly: true) |
| 設定 | `gearshape` | SettingsView |

#### 3.3.0 今日画面（TodayView）

朝刊型のホーム画面。上から順に、AIデイリーブリーフ（当日分がなければ `TodayDigest` がローカルで合成した要約）、変化カード（横スクロール、最大5枚）、スワイプ判定を始めるカード（未判定の物件があるときのみ）、週次相場（折りたたみ）、「すべての動き」へのリンクを表示する。「すべての動き」（ActivityFeedView）は直近7日の新着・再掲・価格変動を最大100件のタイムラインで表示する。今日タブの変化カードと「すべての動き」は、D評価の物件を除外する（`GradeVisibility`。いいね済みの物件は常に表示する）。

#### 3.3.1 ログイン画面（LoginView）

| 要素 | 詳細 |
|------|------|
| **背景** | 青系グラデーション + ウェーブアニメーション（`WaveShape`） |
| **アプリアイコン** | `AppIcon-Login` 画像 |
| **サインインボタン** | Google ブランドガイドライン準拠のボタン |
| **エラー表示** | ホワイトリスト外の場合にエラーメッセージ |

#### 3.3.2 物件一覧画面（ListingListView）

2つのモードで使用する。

- **さがすタブ（リスト）**: `PropertyListingTabView` 経由の `propertyTypeFilter: "chuko"`。掲載中の中古マンションだけを表示する
- **マイリストタブ**: `favoritesOnly: true`。いいね済みの物件を表示する

新築タブは廃止済みで、`ListingListView` は掲載中の中古（`propertyType == "chuko"`）しか読み込まない。

| 機能 | 詳細 |
|------|------|
| **ナビゲーションタイトル** | `.inline` 表示（ナビゲーションバーに固定、スクロールに追従しない）。さがすタブは「中古マンション」、マイリストタブは「マイリスト」 |
| **検索** | 物件名でインクリメンタル検索（`.searchable`） |
| **ソート** | `ListingSortOrder` の各ケース。追加日、価格、徒歩、面積、築年数、㎡単価、坪単価、管理費、修繕積立金、月額維持費、所在階、階建、総戸数、バルコニー面積、偏差値、値上がり率、儲かる確率、お気に入り数、総合スコア、価格妥当性、流動性、競合売出数、予測変動率、AI 推奨、My 指標を、それぞれ昇順または降順で選べる（My 指標は降順のみ）。表示対象の物件にその項目のデータが1件もなければ、選択肢から外れる |
| **フィルタ** | FilterSheet（後述）で条件を指定 |
| **マイリストの絞り込み** | マイリストタブ: すべて / 掲載中 / 掲載終了 / Like / Nope |
| **比較モード** | ツールバーボタンで起動、2〜4件選択 → ComparisonView |
| **CSV エクスポート** | マイリストタブで ShareLink による CSV 出力 |
| **Pull-to-refresh** | 手動データ更新 |
| **スワイプアクション** | いいね / 詳細表示 |
| **コンテキストメニュー** | 長押しでクイックプレビュー（物件名・価格・面積・間取り・徒歩・住所）+ いいね/共有 |

##### カード（行）の表示構成

カードは左に80ptのサムネイル、右に情報の列を置く。サムネイルは `thumbnailURL`（外観写真を優先）を `TrimmedAsyncImage` で余白トリミングして表示し、その下に `highlightBadge` がある物件では `HighlightBadgeView` でマルチソースバッジを出す。右の列は次の順に並ぶ。

| 行 | 要素 | 詳細 |
|----|------|------|
| **1行目** | 物件名 | `.subheadline.weight(.semibold)`、2行まで。掲載終了物件はセカンダリカラー。展開できるグループでは `name`、それ以外では階を含む `nameWithFloor` を表示する |
| | スコアバッジ | `listingScore` と `scoreGradeLetter` がある場合に `ScoreBadge`（グレード文字と点数）を表示 |
| | 星 | 建物単位で Like 済み（`BuildingPreferenceStore`）の場合に黄色の星 |
| | いいねボタン | 赤ハート（いいね済み）/ グレーハート（未いいね） |
| **2行目** | New / 別部屋バッジ | `addedAt` が2日以内の物件に表示する。`isNewBuilding` または `isRelisted` なら赤い「New」、それ以外（既存マンションの別部屋）ならオレンジの「別部屋」 |
| | 所有権/定借バッジ | `OwnershipBadge`。所有権は青シールド、定借はオレンジ時計アイコン |
| | 騰落率バッジ | `ssAppreciationRate`。値上がりは緑の `↑12%`、値下がりは赤の `↓12%` |
| | 偏差値バッジ | `averageDeviation` を `DeviationBadge` で表示。60以上=青、55以上=シアン、50以上=ティール、45以上=オレンジ、未満=グレー |
| | 複数戸売出バッジ | 展開できるグループでない場合に、`duplicateCountDisplay` を紫バッジで表示（例: 3戸売出中） |
| | 写真数・コメント数 | 写真またはコメントがある場合に、カメラアイコンと枚数、吹き出しアイコンと件数を表示 |
| | 掲載終了バッジ | `isDelisted` が true の場合にオレンジバッジ |
| **3行目** | 価格 | `priceDisplayCompact`。価格帯表示に対応（例: 5,980万〜7,280万円）。色は `Color.accentColor` |
| | 価格変動バッジ | `latestPriceChange` が0でない場合に `↓300万 (2/28)` の形式で変動額と日付を表示。`priceChangeDateLabel` が `parsedPriceHistory` の直近エントリの日付を `M/D` 形式で返す。値下がりはブルー、値上がりはオレンジ |
| **4行目** | 月々支払い | `estimatedMonthlyPayment` がある場合に「月々 約X.X万円」を表示。月額費用が揃っていない場合（`hasFullMonthlyCost` が false）は末尾に「〜」を付ける |
| **5行目** | スペック | 間取り、面積（`areaDisplay`。面積帯に対応）、徒歩分数、築年（`builtAgeDisplay`）、階（`floorDisplay`。データなしの場合は省略）、向きを「 · 」で区切って最大2行で表示 |
| **6行目** | 路線・駅名 | `displayStationLine`（例: 東京メトロ丸ノ内線 新宿御苑前駅 徒歩5分） |
| **7行目** | ハザードバッジ | `parsedHazardData.safetyLevel` が `.moderate` 以上の場合のみ。「注意」または「要確認」と件数の集約バッジ、上位2件の具体ラベル、残りの件数（`+N`）を表示 |
| | 通勤時間バッジ | `hasCommuteInfo` の場合に Playground / M3Career への通勤時間（ロゴアイコンと分数）を表示。1行に収まらない場合はハザード行と通勤時間行に分ける |

AI推奨度（`aiRecommendationScore`）またはAI要約（`displayAISummary`）がある物件は、カード下部にAI評価のトグルを表示する。タップすると、星1〜5個の評価、結論（`aiRecommendationSummary`）、次のアクション（`aiRecommendationAction`）が開く。

一覧行内のバッジ（New / 別部屋、騰落率、複数戸売出、価格変動、掲載終了）は、`.padding(.vertical, 2)`、`.padding(.horizontal, 5)`、`cornerRadius: 4` の共通寸法で高さをそろえる。

##### マンション単位グルーピングと展開カード

一覧画面では `buildingGroupKey`（クリーニング済み物件名と区名を連結したキー）が一致する物件を同一マンションとしてグルーピングし、1マンション = 1カードとして表示する（`ListingGroup`）。住所は区名だけを使う（`extractWardFromAddress`）。そのため、番地の有無（大山町と大山町54番5）やSUUMOの住所誤入力（代田と代沢）があっても、マンション名が同じなら1つに集約できる。マンション名は開発会社が一意に登録するので、同一区内に同名の別建物はほぼない。同一敷地内の別棟は、棟名（コート名、タワー名など）で名前から区別できる。

物件名は `cleanListingName` でクリーニングしたあと、すべての空白と中黒（・）を除去し、既知の誤字を補正（レジテンスをレジデンスに）してから比較する。この処理で、ザ・レジデンスとザレジデンスのような表記ゆれを吸収する。

次の項目はSUUMOのデータに不整合が多いため、キーに含めない。

- 価格、間取り、面積、階数: 住戸ごとに異なる
- 駅徒歩: 掲載ページごとに異なる最寄駅が記載される
- 総戸数: 864、255、866のように値が一致しない
- 築年: 2008と2009のようにずれる
- 階建て、権利形態: SUUMOのページによっては取得できず、nilと値の不一致が頻発する

| 条件 | 表示 |
|------|------|
| 初回ロード中（フィルタ結果が空で、`isInitialLoadComplete` が未完了） | スケルトンローディング（`SkeletonLoadingView`: 5行のプレースホルダーカード + シマーアニメーション） |
| グループ内1件のみ | 通常カード（従来通り） |
| グループ内2件以上 | 代表物件のカード + 展開トグル（「同マンションでN戸売出中」と下向きシェブロン） |

展開トグルをタップすると、カード下部に住戸テーブルが表示される。

| 列 | 内容 |
|----|------|
| 間取り | `layout`（例: 3LDK）。その下に `areaDisplay`（例: 72.5㎡）を小さく表示 |
| 価格 | `priceDisplayCompact`（例: 8,980万） |
| 月々 | `estimatedMonthlyPayment`（例: 12.3万）。月額費用が揃っていない場合は末尾に「〜」を付け、算出できない場合は代替記号を表示する |
| 階 | `floorDisplay`（例: 15階/20階建） |

- 各行はボタンとして機能し、タップでその住戸の詳細画面（スワイプページャー）に遷移する
- 展開/折りたたみは `.easeInOut(duration: 0.25)` アニメーション付き
- 展開中は2行目の「複数戸売出バッジ」は非表示（トグルに統合）
- 画像・ローン試算・住まいサーフィン評価は展開に含めない（詳細画面で確認）

#### 3.3.3 フィルタシート（ListingFilterSheet）

シートの上部に、クイックフィルタのチップを横スクロールで並べる。チップは、駅近（徒歩5分以内）、割安物件（価格妥当性60以上）、大規模（100戸以上）、都心3区（千代田区・中央区・港区）、城南エリア（品川区・大田区・目黒区）、3LDK 70m²以上である。その下に、次のセクションを開閉式で並べる。

| フィルタ項目 | 入力形式 | 詳細 |
|-------------|---------|------|
| **価格帯** | プリセットチップ列（横スクロール）と数値入力 | 下限・上限をそれぞれタップ選択（5,000〜15,000万円、1,000万円刻み）。価格未定の物件を含めるチェックは `showPriceUndecidedToggle` が true の場合だけ表示し、`ListingListView` は false を渡す |
| **坪単価** | プリセットチップ列（横スクロール） | 下限・上限をそれぞれタップ選択（200〜500万円/坪、50万円刻み）。坪単価が算出できない物件は除外 |
| **月額支払額** | 数値入力とプリセットチップ | 上限金額（15〜50万円/月）、金利（0.5 / 0.8 / 1.0 / 1.2 / 1.5 / 2.0%、既定1.2%）、返済期間（20 / 25 / 30 / 35 / 40 / 45 / 50年、既定50年）から月額支払額の上限を指定し、計算プレビューを表示する |
| **間取り** | チップ複数選択 | 表示対象の物件にある間取り（1K、1LDK、2LDK、3LDK など）だけを並べる |
| **駅徒歩** | プリセットチップ列 | タップ選択（3 / 5 / 7 / 10 / 15 / 20分以内） |
| **駅名** | プルダウン（路線別）+ チェックボックス | DisclosureGroup で路線を展開し、駅名をチェックボックスで複数選択。路線内一括選択/解除・全選択解除ボタン付き |
| **広さ** | プリセットチップ列 | タップ選択（45 / 50 / 55 / 60 / 65 / 70 / 75 / 80㎡以上） |
| **権利形態** | チェックボックス | 所有権 / 定期借地 |
| **向き** | チップ複数選択 | 表示対象の物件にある向きだけを並べる |
| **エリア（区）** | チップ複数選択 | 東京23区 |
| **数値項目** | 下限・上限の範囲指定 | 築年数、㎡単価、坪単価、管理費、修繕積立金、月額維持費、所在階、総階数、総戸数、バルコニー面積、偏差値、値上がり率、儲かる確率、お気に入り数、総合スコア、価格妥当性、流動性、競合売出数、予測変動率のうち、表示対象の物件にデータがある項目だけを並べる。データの充足率を、未設定セクションの要約に出す |

物件種別（中古/新築）のフィルタ項目は廃止した。フィルタ状態は `FilterStore`（`@Observable`）で、画面ごとに独立して持つ（さがすタブとマイリストタブで干渉しない）。

##### フィルタUI

| 機能 | 詳細 |
|------|------|
| **プリセットチップ列** | 価格帯・坪単価・駅徒歩・広さの入力は、スライダーではなくプリセット値のタップ選択にしている。SUUMO などの不動産アプリと同じ操作感になる |
| **セクション個別クリア** | 値が設定されたセクションのヘッダーに×ボタンを表示。タップでそのセクションのみリセット |
| **アクティブフィルタ数バッジ** | ナビゲーションタイトルにアクティブなフィルタセクション数を表示（例: 「フィルタ (3)」） |
| **アクティブセクション自動展開** | 値が設定されているセクションは初回表示時に自動展開。未設定セクションは折りたたみ |
| **該当件数ボタン** | 画面下部のボタンに、条件に合う件数を「N件の物件を表示」と表示する。0件の場合は「該当する物件がありません」 |

##### フィルタテンプレート

フィルタ条件をテンプレートとして保存し、再利用できる機能。ツールバーのブックマークアイコンメニューから操作する。

| 機能 | 詳細 |
|------|------|
| **保存** | 現在のフィルタ条件に名前を付けて保存（最大5件） |
| **読み込み** | 保存済みテンプレートをタップしてフィルタに即時反映 |
| **リネーム** | テンプレート名を変更 |
| **削除** | テンプレートを個別に削除 |
| **永続化** | UserDefaults に JSON で保存（`realestate.filterTemplates`） |
| **共有範囲** | 画面をまたいで共有（さがすタブとマイリストタブで同じテンプレートリストを使用） |

テンプレート管理は `FilterTemplateStore`（`@Observable`）が担当する。アプリ全体で `.environment()` に注入し、全画面が同じインスタンスを参照する。

#### 3.3.4 物件詳細画面（ListingDetailView / ListingDetailPagerView）

フルスクリーンカバー（`.fullScreenCover`）として表示。一覧画面から開く場合は `ListingDetailPagerView`（スワイプページャー）でラップされ、横スワイプで前後の物件に遷移可能。現在の1物件のみ `ListingDetailView` を生成し、`.id()` で物件切替時にビューを再生成する方式で、メモリ使用量を最小化。`DragGesture` の方向判定で縦スクロールと競合回避。ページャーは画面下部にフローティングのページインジケーター（`< 3 / 15 >`）を表示し、現在位置の把握とタップによる前後移動が可能。

**画面構成**

画面は、上から順にヒーロー領域、タブ切替、タブの中身で構成する。

タブ切替は「概要 / お金 / 資産 / 環境 / メモ」の5つで、segmentedピッカー（`tabPickerHeader`）をスクロール時も画面上部にピン留めする。横スワイプのページャーと操作が重ならないように、切り替えはタップだけにし、中身は `switch` で差し替える（`TabView(.page)` は使わない）。

**ヒーロー領域（タブの上に常に表示）**

| # | セクション | 内容 |
|---|-----------|------|
| ① | **保存エラーの警告** | `SupabaseAnnotationService.shared.lastWriteError` がある場合に、オレンジ色の警告を表示する |
| ② | **掲載終了バナー** | `isDelisted` が true のとき表示 |
| ③ | **物件画像ギャラリー** | `parsedImageCategories` がある場合は `CategorizedImageGallery`（Claudeが分類したカテゴリのタブで切り替える）。ない場合で `hasFloorPlanImages \|\| hasSuumoImages` のときは、従来の `propertyImagesGallery`（下記）を表示する |
| ④ | **物件名** | `nameWithFloor` をタイトル表示。テキスト選択可能（`.textSelection(.enabled)`）で長押しコピーに対応 |
| ⑤ | **住所** | `bestAddress` と、住所と物件名で検索するGoogle Mapsのボタン |
| ⑥ | **スタットストリップ** | 3セルを横に並べる。月々の支払い（約X万）、間取り・面積、徒歩・築年 |
| ⑦ | **AI購入推奨度 / 投資サマリー** | `InvestmentSummaryCard`。`aiRecommendationScore` がある場合は星の評価、結論、フラグ、強み、リスクを表示する。ない場合は、AI要約またはハイライトバッジだけの簡易カードを表示する |

**物件画像ギャラリー（`propertyImagesGallery`）**: 間取り図を先頭に、SUUMOの物件写真（外観・室内・水回り等）を後ろに置いた横スクロールのギャラリー。各画像にラベルを表示する。サムネイル（`GalleryThumbnailView`）とフルスクリーン表示（`GalleryFullScreenView`）のどちらも、白余白を自動トリミングする。長押し（`.contextMenu`）で「画像をコピー」「共有…」を選べる（コピーは `UIPasteboard.general.image`）。タップするとフルスクリーン表示になり、横スワイプで前後の画像に移動できる。下部のミニマップにサムネイルを並べ、タップで直接ジャンプできる。ページインジケーターと画像ラベルを表示し、ツールバー右上にコピーボタンを常設する。コピーが完了するとオーバーレイで知らせる。Firebase Storage経由で、掲載終了後も画像を表示できる。

**タブの中身**

| タブ | セクション | 内容 |
|------|-----------|------|
| **概要** | 物件基本情報、AI抽出特徴、別ソース価格、重複候補、外部リンク | 下記「物件基本情報の表示項目」を表示する。`parsedExtractedFeatures` があれば `ExtractedFeaturesSection`、別サイトの価格は `AlternateSourcesSection`、重複候補は `DedupCandidateCard` で表示する。掲載終了の物件では外部リンクを掲載終了の案内に置き換える |
| **お金** | 月額支払いシミュレーション、お金のシミュレーター | `priceMan > 0` の場合のみ。月額支払いシミュレーションの下に「お金のシミュレーター」ボタンを置く。ボタンは `MoneySimulatorView` をシートで開き、諸費用、銀行比較、減税、賃貸と購入の比較、リノベ費用の5つを前提条件の共有で1画面にまとめる。価格がない物件は「価格情報がありません」を表示する |
| **資産** | 投資スコア、住まいサーフィン評価、周辺相場、シミュレーション、成約相場、近隣の成約事例、マンションレビュー、人口動態、類似物件 | 各セクションはデータがある場合のみ表示する。詳細は次の表 |
| **環境** | 通勤時間、ハザード情報 | 通勤時間は Playground / M3Career への所要時間（MKDirections）とGoogle Mapsへのリンクを表示する。座標があり通勤時間が未取得の場合は計算ボタンを表示する。両方とも未取得の場合は「環境情報は未取得です」を表示する |
| **メモ** | 内見予定と内見モード、AI相談、内見メモ、内見チェックリスト | 内見予定のトグルと「内見モードを開く」ボタンを置く。続けてAI相談（下記）、内見メモのコンパクトボタン（カメラアイコン、コメントアイコン、件数。タップで内見メモのオーバーレイをシートで開き、コメント入力と写真追加はオーバーレイ内で行う）、内見チェックリストを並べる |

内見チェックリストはDisclosureGroupで折りたたむ。日当たり、騒音、共用部の清掃・管理状態、エントランス・セキュリティ、眺望・窓からの景色、水回り、収納スペース、周辺環境、駐車場・駐輪場、におい・換気の10項目を、タップでチェックのオンとオフを切り替える。結果は `checklistJSON` にJSONでローカル保存し、保存がない物件にはデフォルトテンプレート（`ChecklistItem.defaultTemplate`）を表示する。

資産タブの各セクションは次のとおり。

| セクション | 内容 |
|-----------|------|
| **投資スコア** | `listingScore != nil \|\| hasPriceChanges \|\| firstSeenAt != nil` の場合のみ。総合スコア（大数字）+ 価格妥当性/再販流動性のバーチャート + 競合物件数 + 掲載日数 + 価格変動チャート・サマリー。`DisclosureGroup`「スコアの根拠」で各構成要素（価格妥当性・再販流動性・値上がり率・儲かる確率・ハザード・通勤利便性・人口動態）のスコア・重み・根拠詳細をプルダウン表示。`scoreBreakdown` の computed property が、Python の `_calc_listing_score` と同じロジックをiOS側で再現し、各要素のソースデータから根拠テキストを生成する。**価格変動チャート**は、2件以上の `price_history` エントリがある場合に Swift Charts のラインチャートで表示する（X軸は日付、Y軸は価格万円）。**価格変動サマリーカード**は、掲載日数・累計変動額/率・直近変動額を3カラムで表示する（値下がり=緑、値上げ=赤）。テキストリストも併記する |
| **住まいサーフィン評価** | 常に表示。`hasSumaiSurfinData` の場合は評価データ（沖式時価・値上がり率・レーダーチャート等）+ 販売価格割安判定（`hasPriceJudgments` の場合、折りたたみ式サブセクション）を表示。未取得の場合はステータスに応じた案内メッセージを表示 |
| **周辺相場（住まいサーフィン）** | `hasSurroundingProperties` の場合のみ。周辺中古マンションの相場一覧（折りたたみ） |
| **値上がり・含み益シミュレーション** | `hasSimulationData` の場合のみ。`SimulationSectionView` が5年/10年の楽観・標準・悲観の3シナリオ + 含み益チャートを表示する |
| **成約相場との比較** | `hasMarketData` の場合のみ。`MarketDataSectionView` で成約データと比較表示 |
| **近隣の成約事例** | 同一区（`Listing.extractWardFromAddress`）の成約実績を最大5件表示。`.task` で `FetchDescriptor`（`fetchLimit: 5`、区名プレディケート＋取引時期ソート）による遅延フェッチ。各件は `TransactionDetailView` への NavigationLink |
| **マンションレビュー** | `parsedMansionReviewData` がある場合のみ。偏差値、推定適正価格、騰落率、推定坪単価、中古販売履歴の件数を表示し、出典のマンションレビュー（mansion-review.jp）へのリンクを置く |
| **エリア人口動態** | `hasPopulationData` の場合のみ。`PopulationSectionView` で人口推移・高齢化率推移を表示 |
| **類似物件** | `similarListings` が空でない場合のみ。`.task` で遅延フェッチする |

環境タブのハザード情報は、`hasHazardData` の場合のみ表示する。洪水、内水、土砂、高潮、津波、液状化の各リスクレベルを示す。

月額支払いシミュレーションは、`priceMan > 0` の場合にお金タブへ表示する。下記の計算ロジックで動的に算出し、タップでフォームを展開して金利・返済期間・頭金を変更できる。

AI相談セクションは、次の内容を持つ。

| セクション | 内容 |
|-----------|------|
| **AI相談** | `AIConsultationSectionView` が物件情報を生成AIに渡し、購入判断の壁打ちを依頼する。相談フォーカス（`Listing.ConsultationFocus`）は、総合判断、リスク分析、価格交渉、売却出口の4種類から選ぶ。**買い手条件**（`BuyerProfile`）は端末のUserDefaultsに保存し、プロンプトに自動で反映する。設定ボタンは未設定ならオレンジ、設定済みなら緑で表示する。`toAIConsultationPrompt(otherCandidates:buyerProfile:focus:)` が意思決定型のプロンプトを生成する。内容は、戦略分類（標準1軒目向き、例外的短期向き、2軒目向き、特殊物件、見送りの5種類）、推奨スペック、金利耐性（現行、1.5%、2.0%、2.5%、3.0%）、Web検索を必須とする自律リサーチ指示、家族計画と保有年数の整合チェック、情報源の優先順位（一次情報、二次情報、口コミの順）、必須出力フォーマットである。出力フォーマットは、冒頭に戦略分類、購入推奨度、結論、妥当価格、買付上限を示し、そのあとに総合判断の根拠から未確認事項・仲介確認質問までを順に答えさせる。ハザードは自治体公式のハザードマップで必ず確認させる。ChatGPTは `?q=` パラメータでプロンプトを入力済みにしてアプリまたはWebを起動する。Geminiは `googlegemini://`、`googleapp://robin`、Web URLの順に試す。Claudeは `claude://` を試し、開けなければWeb URLを使う。各ボタンにサービスのロゴアイコンを表示する |

##### 月額支払いシミュレーション 計算ロジック

**計算式（元利均等返済）**

```
M = P × r × (1+r)^n / ((1+r)^n - 1)

M = 月額ローン返済額（万円）
P = 借入元本（万円）= 物件価格 - 頭金
r = 月利 = 年利(%) / 100 / 12
n = 返済回数（月）= 返済年数 × 12

月額合計 = M × 10,000 + 管理費(円) + 修繕積立金(円)
返済総額 = M × n
```

**デフォルトパラメータ（iOS / Python 共通）**

| パラメータ | デフォルト値 | 備考 |
|-----------|------------|------|
| 年利 | 1.2% | 変動金利想定（`LoanCalculator.annualRate`、Pythonは `loan_calc.py` の `ANNUAL_RATE_VARIABLE = 0.012`） |
| 返済期間 | 50年 | |
| 頭金 | 0万円 | |
| 管理費 | スクレイピング実額 | SUUMO/HOME'S から取得。未取得時は 0 |
| 修繕積立金 | スクレイピング実額 | 同上 |

**動的フォーム（MonthlyPaymentSimulationView）**

| パラメータ | UI | 範囲 | 刻み |
|-----------|-----|------|------|
| 金利 (%) | Stepper（カード型） | 0.1 ~ 5.0 | 0.01 |
| 返済期間 (年) | Menu（カード型プルダウン、chevron.up.chevron.down アイコン付き） | 20, 30, 35, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50 | — |
| 頭金 (万円) | Slider（カード型） | 0 ~ 物件価格 | 物件価格/100（最小10万円） |

- 各フォーム項目は `systemGray6` 背景 + `systemGray4` ボーダーのカード型レイアウトで統一
- 初期状態: 折りたたみ（デフォルトパラメータで計算した結果のみ表示）
- タップで展開: フォーム表示 + 返済総額（参考）を追加表示
- パラメータ変更時: リアルタイムに月額合計・内訳・返済総額を再計算
- 「デフォルトに戻す」ボタン: デフォルト値と異なる場合のみ表示

**実装ファイル**

| ファイル | 役割 |
|---------|------|
| `LoanCalculator.swift` | 計算ロジック。`monthlyPayment(principal:rate:years:)` / `totalRepayment(principal:rate:years:)`。`simulate(listing:)` は listing URL + 主要パラメータでセッション内キャッシュし、body 再評価時の再計算を回避 |
| `MonthlyPaymentSimulationView.swift` | 動的フォーム付き UI |
| `ListingDetailView.swift` | 物件詳細のメイン画面。body を軽く保つため、各セクションを `@ViewBuilder` の private var に切り出している（`delistedBanner`、`addressSection`、`statStripSection`、`notesCompactButton`、`propertyImagesGallery`、`propertyInfoSection`、`commuteSection`、`hazardSection`、`sumaiSurfinSection`、`surroundingPropertiesSection`、`priceJudgmentsSection`、`similarListingsSection`、`mansionReviewSection`、`externalLinksSection` など）。それらを `overviewTab`、`moneyTab`、`assetTab`、`environmentTab`、`notesTab` に振り分け、`selectedTab`（`DetailTab`）で切り替える。類似物件（`similarListings`）と近隣成約事例（`nearbyTransactions`）は `@State` と `.task` で遅延フェッチする（`FetchDescriptor` と `fetchLimit` で必要最小限のデータだけを取得する）。内見メモ（コメントと写真）は `notesCompactButton`（アイコン表示）をタップすると、`.sheet` で `notesOverlaySheet`（コメントセクションと `PhotoSectionView`）を開く。ギャラリーの型は `GalleryThumbnailView` と `GalleryFullScreenView` で、`ListingDetailViewComponents.swift` にある。フルスクリーン表示は `TabView(.page)` でページングし、前後の画像を先読みする。共有シートは `UIActivityViewController.share(image:)` 拡張で起動する |
| `AIConsultationSectionView.swift` | AI相談セクションと `AIService` enum（トップレベルで定義し、`AIComparisonSheet` と共有する）。物件情報のMarkdownコピーと、ChatGPT / Gemini / Claudeへの相談機能を提供する。`BuyerProfile` の設定ボタンを表示する（未設定ならオレンジ、設定済みなら緑）。`AIService` に `openApp(prompt:)` を定義し、URLスキームを試して失敗したらWebに切り替える処理を共通化している |
| `AIComparisonSheet.swift` | 複数物件のAI比較シート。ComparisonViewのツールバーから表示する。選択された全物件の一覧を表示し、`Listing.toAIComparisonPrompt(listings:buyerProfile:)` で対等比較プロンプトを生成する。買い手条件の設定、Markdownコピー、AIサービス選択（ChatGPT/Gemini/Claude）のUIを提供する |
| `Listing+MarkdownExport.swift` | 物件情報のMarkdown書き出しと、AI相談プロンプト（`toAIConsultationPrompt(otherCandidates:buyerProfile:focus:)`）、AI比較プロンプトの生成 |
| `BuyerProfile.swift` | AI相談プロンプトに含める「買い手条件」モデル。家族構成、世帯年収、自己資金、借入条件、金利タイプ、月額上限、働き方、子ども予定、住み替え理由、売却後の方針、重視ポイント、希望エリア、シナリオなどを持つ。UserDefaultsにJSONで保存し、`toMarkdownSection()` でプロンプト用のMarkdownテーブルを生成する。`BuyerProfileSyncService` がSupabaseの `buyer_profiles` テーブルと同期する |
| `BuyerProfileSheet.swift` | 買い手条件の入力・編集シート。FormベースのUI。「家族・ライフスタイル」「エリア・住環境」「資金計画」「将来の計画」「シナリオ」の5セクション構成。NavigationStackにキャンセルと保存のボタンを置く |
| `ListingDetailPagerView.swift` | 物件スワイプページャー。`listings` と `initialIndex` を受け取り、現在の1物件だけ `ListingDetailView` を生成する。横スワイプ（`DragGesture` と方向判定で、縦スクロールとの競合を避ける）で前後の物件に切り替え、`.id()` で物件切替時にビューを再生成する。画面下部にフローティングのページインジケーター（`.regularMaterial` と `Capsule`）を表示する。一覧画面の `.fullScreenCover(item:)` から、フィルタ後の物件配列とタップされた物件のインデックスを受け取って初期表示する |
| `loan_calc.py` (Python) | Slack 通知・レポート用の月額計算（同一パラメータ） |

**物件基本情報の表示項目**

| 項目 | 内容 |
|------|------|
| 最寄駅 | 複数駅に対応。物件情報の先頭に表示する |
| 価格 | `priceDisplay` |
| 坪単価（万円/坪） | |
| 売出戸数 | 複数戸売出時のみ |
| 間取り | |
| 面積 / 坪数 | |
| 築年 | |
| 所在階 / 階建 | |
| 総戸数 | |
| 向き | データがある場合のみ |
| バルコニー面積 | データがある場合のみ |
| 権利形態 | データがある場合のみ。`OwnershipBadge` で表示 |
| 用途地域 | データがある場合のみ |
| 駐車場 | データがある場合のみ |
| 施工会社 | データがある場合のみ |
| 修繕積立基金 | データがある場合のみ |
| 引渡時期 | データがある場合のみ |
| 特徴タグ | データがある場合に、FlowLayoutでチップ表示 |
| 種別 | 中古マンション |

**住まいサーフィン関連のセクション（資産タブ）**

| セクション | 内容 |
|-----------|------|
| **住まいサーフィン評価（中古）** | 沖式中古時価（実面積/70㎡換算）、中古値上がり率（未取得時は代替記号を表示）、割安判定バッジ、レーダーチャート（6軸偏差値）、駅・区ランキング、販売価格割安判定（`hasPriceJudgments` の場合。後述） |
| **周辺相場** | `hasSurroundingProperties` の場合のみ。周辺の中古マンション相場を表示（後述） |

##### 周辺相場セクション

**データ取得**

住まいサーフィンの中古・新築物件ページから「周辺の中古マンション相場」テーブルを HTML パースで取得する（`sumai_surfin_enricher.py` `_extract_surrounding_properties()`）。

| 取得フィールド | 型 | 説明 |
|------------|------|------|
| `name` | String | 周辺マンション名 |
| `url` | String? | 住まいサーフィン物件 URL（リンクが存在する場合） |
| `appreciation_rate` | Double? | 中古値上がり率（%）。**取得にはログインが必須**（取得前に必ずログイン済みセッションを使用すること）。非ログイン時は `XX%` でマスクされ数値を取得できない。マスク値検出時は警告を出力する。取得できなかった場合も `null` としてキーを必ず含め、iOS 側で「未取得」を明示表示する |
| `oki_price_70m2` | Int? | 沖式中古時価 70㎡換算（万円）。500万円未満は除外 |

**格納フィールド:** `ss_surrounding_properties`（JSON 文字列）

**表示条件:** `hasSurroundingProperties` = `ss_surrounding_properties != nil && parsedSurroundingProperties が空でない`

**UI 仕様**

- 折りたたみ式セクション（初期: 折りたたみ）
- ヘッダー: 「周辺の中古マンション相場」+ 件数
- 展開時の各行は次の内容を表示する
  - 物件名（URLがある場合はタップでSafari遷移）
  - 中古値上がり率（正=緑、負=赤、未取得時は代替記号をグレー表示）
  - 沖式中古時価 70㎡換算（万円）

##### 販売価格割安判定セクション（住まいサーフィン評価セクション内に表示）

**データ取得**

住まいサーフィンの中古物件ページで「販売価格が割安か判定する」ボタンをブラウザ自動化（Playwright）でクリックし、判定結果を取得する（`sumai_surfin_browser.py` `extract_chuko_price_judgments()`）。中古物件のみ対象。住まいサーフィン評価セクション（`sumaiSurfinSection`）内の末尾に、Dividerを挟んで折りたたみ式サブセクションとして表示する。

取得フローは次のとおり。

1. `#js-usedprice-judge-exec` ボタンをクリック
2. `#js-usedprice-judge-result-text` から判定テキストを取得
3. 複数住戸の場合は、`.u-sellPrice_roomNumber.-navi` を順にクリックし各住戸の判定を収集
4. 各住戸の階数・価格・面積・間取りを `_extract_current_slide_info()` で抽出
5. フォールバック: API `/common/data/judge_usedprice.php` 直接呼び出し、正規表現抽出

| 取得フィールド | 型 | 説明 |
|------------|------|------|
| `unit` | String? | 住戸情報（例: `"6階/23階"`） |
| `price_man` | Int? | 販売価格（万円） |
| `m2_price` | Int? | m²単価（万円） |
| `layout` | String? | 間取り（例: `"2SLDK"`） |
| `area_m2` | Double? | 面積（㎡） |
| `direction` | String? | 向き |
| `oki_price_man` | Int? | 沖式中古時価（万円） |
| `difference_man` | Int? | 差額（万円、マイナス=割安） |
| `judgment` | String? | 判定ラベル（`割安` / `やや割安` / `適正` / `やや割高` / `割高`） |

**格納フィールド:** `ss_price_judgments`（JSON 文字列）、`ss_value_judgment`（代表判定文字列）

**表示条件:** `hasPriceJudgments` = `ss_price_judgments != nil && parsedPriceJudgments が空でない`

**代表判定の決定ロジック（`computedPriceJudgment`）**

判定ラベル（割安・やや割安・適正価格・やや割高・割高）は住まいサーフィンが提供するデータをそのまま使用する。独自の閾値による計算は行わない。

優先順位は次のとおり。

1. `ssValueJudgment`。ブラウザ自動化で取得した代表判定（「販売価格が割安か判定する」ボタン押下結果）
2. `ssPriceJudgments`。住戸ごとの判定から、掲載価格（`priceMan`）に最も近い住戸の `judgment` を採用する（1住戸なら即採用、掲載価格なしの場合は先頭住戸）
3. データなしの場合は `nil`（判定バッジを非表示）

**UI 仕様**

- 住まいサーフィン評価セクション（`sumaiSurfinSection`）内の末尾に、Dividerを挟んで表示
- 折りたたみ式サブセクション（初期: 折りたたみ）
- ヘッダーは「販売価格 割安判定」+ 割安住戸サマリ（例: `2/5戸割安`、割安なしの場合は `5戸`）
- 展開時の各行は次の内容を表示する
  - 1行目: 住戸情報（階数）、間取り、面積 + 判定バッジ
  - 2行目: 販売価格、沖式時価、差額（マイナス=緑、プラス=赤）
- 判定バッジの色は次のとおり
  - `割安` / `やや割安` は緑（`positiveColor`）
  - `割高` / `やや割高` は赤（`negativeColor`）
  - `適正` / `適正価格` はオレンジ
  - その他はグレー

アプリは新築マンションを表示しないので、新築向けの住まいサーフィン評価と10年後予測の詳細は、現在の画面にない。

#### 3.3.5 地図画面（MapTabView）

| 機能 | 詳細 |
|------|------|
| **地図表示** | MKMapView（`UIViewRepresentable` でラップ）に、座標を持つ物件をピンで表示する。座標がない物件は住所をジオコーディングして取得し、取得中の件数を「N件 座標取得中」と表示する。取得できなかった住所は件数をアラートで知らせ、再取得できる |
| **ピンクラスタリング** | ズームアウト時に近接ピンをクラスターに集約し、件数を表示する（青） |
| **ピン色分け** | いいね済みは赤のハート。それ以外は `listingScore` に応じたスコア色の建物アイコンで、スコアがない物件は青 |
| **ピンタップ** | コールアウトに物件概要、いいねボタン、詳細ボタンを表示し、詳細ボタンで物件詳細へ遷移する |
| **フィルタ** | `FilterStore` を画面ごとに持ち、一覧と同じ `ListingFilterSheet` で条件を指定する |
| **現在地ボタン** | ボタンで現在地の表示を切り替える（`showsUserLocation`） |
| **成約相場ヒートマップ** | 「成約相場」トグルで、成約データの㎡単価を5段階（安い緑から高い赤）の円で重ねて表示する（`HeatmapBucketer`） |
| **凡例** | 物件（青）と、いいね（赤のハート）の凡例 |

##### ハザードマップオーバーレイ

シートで表示と非表示を切り替える。次のレイヤーを、国土地理院のラスタータイル（`MKTileOverlay`）で重ねる。

| カテゴリ | レイヤー |
|---------|---------|
| **基本** | 洪水浸水想定、内水浸水想定、土砂災害警戒区域、高潮浸水想定、津波浸水想定、液状化（地形分類）※1 |
| **洪水詳細** | 浸水継続時間、家屋倒壊（氾濫流）、家屋倒壊（河岸侵食） |
| **地盤** | 揺れやすさ（地形分類）※1 |

> ※1 液状化リスク・揺れやすさの GSI オリジナルタイル（`08_liquid`・`13_jibanshindou`）は非公開(404)のため、代替として国土地理院 治水地形分類図（`lcmfc2`）を使用。地形種別（旧河道・後背湿地等）からリスクを間接的に判読する。

**タイルズーム制限（`maxNativeZoom`）**: GSI タイルのデータ公開ズームレベルはレイヤーにより異なる。`MKTileOverlay.maximumZ` をレイヤーごとの `maxNativeZoom` に設定し、超過ズームでは最大ズームタイルを拡大表示する。

| レイヤー | maxNativeZoom | 備考 |
|---------|:---:|------|
| 洪水・土砂・高潮・浸水継続・液状化・揺れやすさ | 17 | フル対応 |
| 家屋倒壊（氾濫流・河岸侵食） | 13 | z≥14 は拡大表示 |
| 津波浸水想定 | 11 | z≥12 は拡大表示 |
| 内水浸水想定 | 9 | 東京都は z=9 まで（都府県によりデータ範囲が異なる） |

##### 東京都地域危険度オーバーレイ

| レイヤー | データソース |
|---------|------------|
| **建物倒壊危険度** | GeoJSON（GitHub raw）を `MKPolygon` に変換し、ランク1〜5で色分け |
| **火災危険度** | 同上 |
| **総合危険度** | 同上 |

#### 3.3.6 設定画面（SettingsView）

| セクション | 項目 |
|-----------|------|
| **通知** | 通知頻度、通知時刻、コメント通知のトグル、通知許可の状態と設定アプリへの導線 |
| **データ** | 最近見た物件（NavigationLink → RecentlyViewedListView）、成約事例（`TransactionTabView` をシートで開く）、中古マンションの件数、最終更新、未通知の新着件数、フルリフレッシュ |
| **My指標** | 価格妥当性、再販流動性、総合スコア、駅近（徒歩）、AI推奨度の5つの重みをスライダー（0〜1、0.05刻み）で設定する。一覧のソート「My指標（高い順）」で使う合成スコアの重みで、データが欠けている項目は計算から自動で除外する |
| **検討サポート** | 買付準備（`PurchaseReadinessView`）、通勤先設定（NavigationLink → CommuteDestinationSettingsView） |
| **アカウント** | ユーザー情報表示、ログアウト |
| **開発者** | バージョン行を7回連続でタップすると表示する。スクレイピングログ（`ScrapingLogView`）、データ取得元をSupabase APIにするかのトグル、カスタムURLの保存と既定への復帰、診断情報、開発者モードを隠す操作を置く |
| **このアプリについて** | 使い方ガイド（ウォークスルーの再表示）、バージョンとビルド番号 |

スクレイピング条件の設定画面（`ScrapingConfigView`）とサービス（`ScrapingConfigService`）は、アプリから削除済みである。スクレイピング条件の正は `ScrapingConfigMetadata.json` と、Supabaseの `scraping_config` テーブルが持つ。

#### 3.3.7 物件比較画面（ComparisonView）

- 2〜4件を横並びで比較
- 横スクロール `Grid` レイアウト（行高が全列で自動同期）
- 比較項目: 価格、間取り、面積、築年、徒歩、階数、総戸数、権利形態、住まいサーフィン評価
- **AIで比較**: ツールバーの「AIで比較」ボタンで `AIComparisonSheet` を表示する。選択した全物件の詳細情報を含む比較プロンプトを生成し、ChatGPT / Gemini / Claude に対等比較とランキングを依頼する
- **PDFエクスポート（p6-03）**: ツールバーの「PDF出力」ボタンでA4の比較シートを生成し、UIActivityViewControllerで共有する（ファイル保存、AirDrop、メールなど）

#### 3.3.8 内見写真（PhotoSectionView）— 内見メモオーバーレイ内に表示

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

#### 3.3.10 通勤先設定画面（CommuteDestinationSettingsView）

設定画面の「通勤先設定」から遷移。通勤時間計算・Google Maps 連携で参照する目的地を最大3箇所まで設定可能。

| 要素 | 詳細 |
|------|------|
| **一覧表示** | 設定済み通勤先の名前・座標を表示。スワイプで削除 |
| **追加** | 名前＋住所を入力し、CLGeocoder でジオコーディングして追加。最大3箇所まで |
| **デフォルト復元** | 通勤先2拠点（オフィスA・オフィスB）に戻す。実値は gitignore 対象の `CommuteOffices.plist` から読み込み、ファイルがない場合は座標0,0のプレースホルダになる |
| **永続化** | UserDefaults（`commuteDestinations`）に JSON で保存。CommuteData 構造は従来のまま（playground/m3career）で、MKDirections 計算は固定2箇所を継続使用 |

#### 3.3.11 成約実績一覧（TransactionListView）

| 要素 | 詳細 |
|------|------|
| **グルーピング** | `buildingGroupId`（町丁目コード+築年）単位で推定建物グルーピング |
| **折りたたみ** | 各建物グループの取引行はデフォルト折りたたみ。ヘッダータップで開閉（`expandedGroups: Set<String>` で状態管理、アニメーション付き）。ヘッダー右端にシェブロン表示 |
| **グループヘッダー** | 推定物件名（or 住所+築年）、件数バッジ、最寄駅・徒歩・構造、価格帯・平均 m² 単価 |
| **取引行** | 成約価格、間取り、面積、m² 単価、取引時期。タップで TransactionDetailView をシート表示 |
| **サマリー** | 上部に全体件数・推定建物数・フィルタリセットボタン |

#### 3.3.12 成約詳細（TransactionDetailView）

| 要素 | 詳細 |
|------|------|
| **地図** | 座標がある場合に地図+マーカー表示 |
| **取引情報** | 成約価格、m² 単価、面積、間取り、取引時期 |
| **建物情報** | 推定物件名、所在地、築年、構造、推定最寄駅・徒歩 |
| **m² 単価推移チャート** | 類似面積（±15㎡）の全成約データを 2LDK / 3LDK の2シリーズで折れ線表示（Swift Charts）。X軸: 四半期、Y軸: 平均 m² 単価（万円/㎡）。閲覧中レコードの時期を縦破線でハイライト |
| **同一建物の成約** | 同一 `buildingGroupId` の他の取引を折りたたみ式で表示（デフォルト閉）。ヘッダータップで開閉、閲覧中レコードにチェックマーク |
| **このエリアの販売中物件** | 同一区（`record.ward`）の販売中物件（`!isDelisted`）を最大5件表示。`Listing` を `@Query` で取得し、区名でフィルタ。各件は `ListingDetailView` への NavigationLink |
| **注意書き** | データソース・匿名化・推定値に関する免責 |

#### 3.3.12-b 成約↔販売物件のクロスリファレンス（Phase 5）

物件詳細と成約詳細の相互参照により、同一エリアの相場を横断的に確認できる。

| 画面 | 追加セクション | 内容 |
|------|----------------|------|
| **ListingDetailView** | 近隣の成約事例 | 同一区の成約実績（`TransactionRecord`）を最大5件。取引時期の新しい順。タップで成約詳細へ |
| **TransactionDetailView** | このエリアの販売中物件 | 同一区の販売中物件（`Listing`、掲載終了を除く）を最大5件。タップで物件詳細へ |

マッチング条件は区名（`ward`）のみ。Listing は `extractWardFromAddress` で住所から区を抽出、TransactionRecord は `ward` プロパティを直接使用。

#### 3.3.13 ホーム画面ウィジェット（WidgetKit）

| 項目 | 詳細 |
|------|------|
| **拡張機能** | RealEstateWidget（WidgetKit アプリ拡張） |
| **Bundle ID** | com.hanawa.realestate.app.widget |
| **表示名** | 物件情報ウィジェット |
| **サイズ** | 小（systemSmall）・中（systemMedium） |
| **ウィジェット名** | 今日の1枚（説明文: 新着の注目物件とAIブリーフを表示します） |
| **データ共有** | App Group `group.com.hanawa.realestate` 経由で UserDefaults にサマリを保存。注目物件の画像は `WidgetImageStore` が共有する |
| **更新タイミング** | ListingStore の refresh 完了時に WidgetDataProvider がデータを書き込み、`WidgetCenter.reloadAllTimelines()` で再描画を要求 |
| **小ウィジェット** | 注目物件（`featuredItems`）の先頭1件を、画像、NEW バッジ、グレード、価格、物件名で表示する。タップでその物件の詳細を開く。注目物件がない場合は、新着件数と全件数を表示する |
| **中ウィジェット** | AI ブリーフ（`briefText`。なければ「今日の新着」の見出し）と、注目物件の上位2件を一覧表示する。注目物件がない場合は、新着件数、全件数、いいね件数と、いいね物件の上位3件の名前を表示する |

### 3.4 サービス層

#### 3.4.1 ListingStore（物件データ取得・同期）

| 項目 | 詳細 |
|------|------|
| **データソース** | 既定は Supabase API（`useSupabase` が true）。`ListingStore.refresh` が `SupabaseListingStore.refresh` に処理を渡す。設定画面の開発者セクションでカスタム URL を保存し、`useSupabase` を false にした場合だけ、JSON を直接取得する |
| **Supabase の取得方式** | リスト・マップ用に軽量ビュー `listings_feed_light` を100件ずつページングして読み、詳細画面は `get_listing_detail` RPC で全 enrichment を遅延ロードする。初回は全件取得（いいね済みで掲載終了の物件も追加で取得）、2回目以降は `lastSync` 以降に `updated_at` が変わった物件と、掲載終了になったキーだけを取得する。`syncVersion`（現在4）が古い場合は同期状態を消して全件を再取得する |
| **中古のみ** | 同期のたびに `purgeNonChukoListings` で中古以外を端末から削除する |
| **カスタム URL（JSON モード）** | 設定画面から変更でき、UserDefaults に保存する。中古のみ取得する |
| **同期方式** | `identityKey` でマッチして更新/挿入/削除する。Supabase では、Supabase の `identity_key`（`supabaseIdentityKey`）を優先し、一致しなければ Swift 側で計算した `identityKey` で照合する。更新時は `update(existing:from:)` で既存の Listing に新フィールドを含めて全件コピーする |
| **ETag キャッシュ（JSON モード）** | レスポンスの ETag を保存し、`If-None-Match` で 304 を判定する。SwiftData が空の場合は ETag を消して全件取得を強制する |
| **304 時の DB 負荷軽減（JSON モード）** | 304 Not Modified の場合、`isNew == true` の物件だけを DB から取得する。データ未変更時は全件取得をスキップする |
| **変更なし時のアノテーション同期スキップ（JSON モード）** | 取得結果に変更がなかった場合は、`pullAnnotations` をスキップして Supabase の読み取りを減らす |
| **WidgetKit 連携** | refresh 完了後に `WidgetDataProvider` が全件数、新着数、いいね数、いいね物件サマリ、注目物件（`WidgetFeaturedSelector`）、AI ブリーフを App Group の UserDefaults に書き込み、ウィジェットのタイムラインを再読み込みする |
| **JSON デコード** | `Task.detached(priority: .userInitiated)` でバックグラウンド実行 |
| **新規検出** | サーバーサイド判定: スクレイピングパイプライン（`finalize_helpers.py inject-new`）が `previous.json` との `identity_key` ベース差分比較で `is_new` フラグを `latest.json` に注入し、`sync_db.py` が Supabase にも同期する。さらに `building_key`（正規化物件名+区名）で前回データに同一マンション名が存在するかを判定し、`is_new_building` フラグも注入（true=新規マンション、false=既存マンションの別部屋）。iOS アプリは DTO の `is_new` / `is_new_building` をそのまま `isNew` / `isNewBuilding` に反映（クライアントサイドでの独自判定は行わない）。既存物件の `isNew` / `isNewBuilding` は同期ごとにリセット。304 Not Modified 時もリセットし、New バッジが残り続けないようにする。`identityKey` は Python 側と同一ロジック（`cleanListingName` で正規化した物件名・駅名のみ抽出・`walk_min` 除外）で、Slack 通知・地図・プッシュ通知・iOS アプリで一貫した新規判定を行う |
| **自動更新** | フォアグラウンド復帰時に15分経過していれば自動 refresh。復帰時にローカル通知の累積カウント・バッジもリセット |
| **lastError** | メインの JSON 取得・同期エラー（致命的）。UI に表示 |
| **syncWarning** | 非致命的な同期警告（いいね・コメントの同期、通勤時間計算など）。`pullAnnotations` / `calculateForAllListings` 失敗時に設定。UI で任意表示可能 |
| **fetchCount エラー** | `fetchCount` 失敗時は do/catch でログ出力し、デフォルト 0 でフルフェッチを強制 |

#### 3.4.2 SupabaseAnnotationService（いいね・コメントの同期）

旧 `FirebaseSyncService`（Firestore の `annotations` を使う実装）は削除済みである。`SupabaseAnnotationService` が同じ操作をSupabaseに対して行う。認証はFirebase AuthのUIDを `user_id` に使い、アクセス制御はSupabase側のSECURITY DEFINERのRPCが担う。

| 操作 | 詳細 |
|------|------|
| **いいね同期** | `pushLikeState(for:)` が `isLiked` をSupabaseに書き込む |
| **コメント追加** | `addComment(for:text:modelContext:)` |
| **コメント編集** | `editComment(for:commentId:newText:modelContext:)` |
| **コメント削除** | `deleteComment(for:commentId:modelContext:)` |
| **プル同期** | `pullAnnotations(modelContext:onError:)` が全 annotations を取得してローカルの SwiftData に反映する。`onError` で失敗時にコールバックする（ListingStore の `syncWarning` 設定用） |
| **初回の一括送信** | `pushAllLocalAnnotationsIfNeeded(modelContext:)` が、端末にあるいいね・コメントを初回だけSupabaseに送る |
| **書き込みエラー** | `lastWriteError` に保持し、物件詳細の画面上部に警告を表示する |

写真のメタデータだけは、今もFirestoreの `annotations/{docID}.photos` に書く（`PhotoSyncService`）。ドキュメントIDはSHA256(`identityKey`)の先頭16文字である。

#### 3.4.3 CommuteTimeService（通勤時間計算）

通勤時間データは2段階で取得する。

1. **パイプライン側（即時表示用）**: `commute_enricher.py` が駅名ベースのドアtoドア概算を `commute_info` としてJSONに付与する。アプリ起動時にすぐ表示できる
2. **iOS側（高精度更新）**: `CommuteTimeService` がMKDirections（Apple Mapsの公共交通機関）でより正確な経路を取得し、パイプラインのデータを上書きする

| 項目 | 詳細 |
|------|------|
| **パイプライン初期データ（駅テーブル）** | `commute_enricher.py` が `station_line` + `walk_min` から駅ベースの概算を付与（`commute_info` フィールド）。`Listing.from(dto:)` で `commuteInfoJSON` に取り込み |
| **パイプライン高精度データ（Google Maps）** | `commute_gmaps_enricher.py` が Playwright で Google Maps をスクレイピングし、物件住所 → 各オフィスの door-to-door 通勤時間を取得。`source: "gmaps"` フラグ付きで `commute_info` に格納。到着時刻: 平日朝 9:00 JST。初回のみ全件取得、以降は新着・未取得のみ。並列ワーカー対応 |
| **iOS 計算方式** | `source: "gmaps"` のデータがある物件は MKDirections 再計算をスキップ。それ以外は MKDirections（公共交通機関モード、`requestsAlternateRoutes = true`）で計算 |
| **目的地** | デフォルトの通勤先2箇所（slug: `playground` / `m3career`）。実住所・名称は、iOS側ではgitignore対象の `CommuteOffices.plist`、パイプライン側では環境変数 `COMMUTE_OFFICES_JSON`（またはSupabase）で管理し、リポジトリにはプレースホルダだけを置く。設定画面の「通勤先設定」で最大3箇所までカスタマイズ可能（CommuteDestinationConfig）。MKDirections 計算は従来の固定2箇所を継続使用（CommuteData 構造の互換性のため） |
| **キャッシュ** | `Listing.commuteInfoJSON` に JSON 文字列で保存 |
| **再計算条件** | `source: "gmaps"` でない物件のうち、未計算、フォールバック概算（`経路情報取得不可`）、7日以上経過のいずれかに当てはまるもの |
| **リトライ戦略** | 1回目: departureDate（次の平日8:00）→ 2回目: 日時指定なし → 3回目: arrivalDate（次の平日9:00）→ フォールバック概算。各リトライ間に2秒待機 |
| **シミュレータ対応** | `#if targetEnvironment(simulator)` でリトライをスキップし即座にフォールバック概算を使用（MKDirections Transit はシミュレータ非対応） |
| **ダウングレード防止** | 既存データがパイプライン/MKDirections の正規経路で、新結果がフォールバック概算の場合は上書きしない |
| **同期時の更新ロジック** | `update(existing:from:)` で `source: "gmaps"` のパイプラインデータは常に取り込む（既存 MKDirections データを上書き）。非 gmaps データは既存が nil or フォールバック概算の場合のみ取り込み |
| **座標バージョン管理** | 目的地座標変更時に UserDefaults でバージョン管理、全件再計算（gmaps データは対象外） |
| **並列 MKDirections** | `withTaskGroup` で concurrency=2 の並列計算。バッチ MainActor 更新でホップ数を削減。大量物件で約 40–50% 高速化 |
| **Google Maps 連携** | ディープリンクで Google Maps アプリ（またはブラウザ）を起動。origin は「住所テキスト（bestAddress）+ 物件名」のテキスト検索で指定（座標は誤差が大きいため使用しない） |
| **注釈表示** | `source: "gmaps"` の場合は「Google Maps の経路検索に基づく自動計算です（平日朝 9:00 到着）」、それ以外は「Apple Maps の公共交通機関経路に基づく参考値です（Google Maps と異なる場合があります）」 |
| **onError コールバック** | `calculateForAllListings(modelContext:onError:)` の `onError` で失敗時にコールバック（ListingStore の syncWarning 設定用） |

#### 3.4.4 通知サービス

| サービス | 種類 | 詳細 |
|---------|------|------|
| **NotificationScheduleService** | ローカル通知 | 新規物件追加時に蓄積 → スケジュール時刻にまとめて配信。新コメント・新写真も通知。アプリがフォアグラウンドに復帰した時点で累積カウント・バッジ・デリバリー済み通知をリセットし、その後の refresh で見つかった新着のみ再カウントする。 |
| **PushNotificationService** | FCM リモート通知 | トピック `new_listings` を購読。GitHub Actions からスクレイピング後に送信。 |
| **BackgroundRefreshManager** | バックグラウンド更新 | `BGAppRefreshTask` で定期的にデータを取得 → 新着検出 → ローカル通知。バックグラウンドでは、いいね・コメントの同期と通勤時間計算をスキップする |

#### 3.4.5 その他のサービス

| サービス | 役割 |
|---------|------|
| **NetworkMonitor** | NWPathMonitor でネットワーク接続状態を監視。オフラインバナー表示に使用。 |
| **PhotoStorageService** | ローカルファイルシステムへの写真保存/読込/削除。NSCache でメモリキャッシュ。 |
| **PhotoSyncService** | Firebase Storage への写真アップロード/ダウンロード/削除。 |
| **SupabaseClient** | Supabase の REST API（PostgREST）を呼ぶ軽量な HTTP クライアント。SDK は使わず、URLSession と JSON で通信する。 |
| **SupabaseListingStore** | 物件データを Supabase から取得して SwiftData に同期する（3.4.1 を参照）。 |
| **AnnotationRouter** | View から `SupabaseAnnotationService` を呼ぶときの窓口。View は直接サービスを呼ばず、このルーターを経由する。 |
| **BuyerProfileSyncService** | Supabase の `buyer_profiles` テーブルと、UserDefaults のローカルキャッシュを同期する。 |
| **DailyBriefService** | Supabase の `buyer_daily_briefs` テーブルから AI デイリーブリーフを読む。生成はリポジトリ外の日次ルーチンが行い、iOS は読むだけである。 |
| **BuildingPreferenceStore** | 建物単位の Like / Nope を保持する。 |
| **InspectionScheduleStore** | 「内見予定」フラグを `identityKey` 単位で UserDefaults に保存する。いいねとは独立している。 |
| **TransactionStore** | `transactions.json` の取得と SwiftData への同期。ListingStore と同様に ETag で差分を判定する。 |
| **ImagePipeline** | 画像の取得、トリミング、キャッシュを一元管理する。メモリ、ディスク、ネットワークの3層で解決し、同じ URL への重複リクエストを防ぐ。 |
| **UserAnnotationStore** | スキーマ変更で DB を作り直す前に、いいね・コメント・メモ・チェックリスト・写真メタデータを UserDefaults にバックアップし、次回の同期で `identityKey` を照合して復元する。 |
| **SwipeProgressStore** | スワイプセッションの進捗（未消化デッキの並びと「あとで」にした物件）を保存する。 |
| **ScrapingLogService** | Firestore の `scraping_logs/latest` からパイプラインログを取得する。開発者セクションの `ScrapingLogView` が表示する。 |
| **SaveErrorHandler** | SwiftData 保存エラーのハンドリング。エラーダイアログ表示。 |
| **WidgetDataProvider** | 物件サマリ（全件数・新着数・いいね数・いいね物件一覧・注目物件・ブリーフ）を App Group の UserDefaults に書き込み、WidgetKit ウィジェットに表示する。ListingStore の refresh 完了時に呼び出される。 |
| **WidgetImageStore** | ウィジェットに表示する注目物件の画像を、ダウンサンプルした JPEG として App Group のコンテナに保存する。 |
| **SpotlightIndexer（p6-02）** | CoreSpotlight 連携。いいね済み物件を Spotlight にインデックス。いいね ON/OFF 時に indexListing / deindexListing を呼び出し、データ同期完了時に reindexAll で全件再構築。 |
| **PDFExporter（p6-03）** | 物件比較シートを A4 PDF として生成。UIGraphicsPDFRenderer で価格・面積・間取り・住所等の比較表を描画。 |
| **ModelContainer 初期化失敗** | ディスク・インメモリ両方失敗時は `fatalError` でクラッシュ。メッセージにエラー内容・再インストール・ストレージ確認を案内。 |

### 3.5 ローンシミュレーション

#### 3.5.1 アプリ独自の計算条件

| パラメータ | 値 |
|-----------|-----|
| **想定価格** | 物件の掲載価格（`priceMan`）。ない場合は沖式時価（`ssOkiPriceForArea`、`ssOkiPrice70m2` の順） |
| **金利** | 1.2%（変動、`LoanCalculator.annualRate`） |
| **返済期間** | 50年（`LoanCalculator.termYears`） |
| **頭金** | 0万円 |

#### 3.5.2 住まいサーフィンとの違い

| 項目 | アプリ | 住まいサーフィン |
|------|--------|----------------|
| 想定価格 | 物件の掲載価格 | 6,000万円（`siteDefaultSimPrice`。基準価格を取得できない場合のフォールバック） |
| 金利 | 1.2% | 0.79% |
| 返済期間 | 50年 | 35年 |

住まいサーフィンからは**変動率（%）のみ**を取り込み、予測価格・ローン残高・含み益はアプリ独自のパラメータで再計算する。

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

共通のデザイントークンを一元管理する。`DesignSystem` に既存のトークンを、`DS`（`Spacing`、`Radius`、`Opacity` など）に新しいトークンを置く。

| トークン | 用途 |
|---------|------|
| **余白** | `listRowVerticalPadding`, `listRowHorizontalPadding`, `DS.Spacing` |
| **角丸** | `cornerRadius`, `DS.Radius` |
| **フォントスタイル** | `ListingObjectStyle`（title / subtitle / caption / detailValue / detailLabel） |
| **色** | `positiveColor`, `negativeColor`, `priceDownColor`（ブルー）, `priceUpColor`（オレンジ）, `commutePGColor`, `commuteM3Color`, `cardBackground`、スコア色（`scoreS`〜`scoreD`）、情報源色（`srcSuumo` など） |
| **透明度** | `DS.Opacity` |
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
| `tab-map` | 地図画面のハザードシートで使うアイコン |
| `tab-chuko`, `tab-shinchiku`, `tab-favorites`, `tab-settings`, `icon-hazard` | アセットカタログにあるが、Swift のコードからは参照していない（タブバーは SF Symbols を使う） |
| `logo-m3career`, `logo-playground` | 通勤バッジロゴ |
| `logo-chatgpt`, `logo-gemini`, `logo-claude` | AI 相談ボタンのサービスロゴ |

#### 3.6.4 SwiftUI ForEach の識別子

`ForEach` では `id: \.offset` を使わず、データモデル由来の安定した識別子を指定する。`\.offset` はSwiftUIのdiffで誤動作を引き起こし得るため禁止する。

| データ | 推奨 id |
|--------|---------|
| ハザードラベル `(icon, label, severity)` | `\.element.label` |
| `QuarterlyPrice` | `\.element.quarter` |
| `YearValue` (人口推移) | `\.element.year` |
| 凡例 `(color, label)` | `\.element.label` |
| 固定長インデックス（レーダー軸・通知時刻など） | `ForEach(0..<count, id: \.self)` で index アクセス |
| `SameBuildingTransaction`（区別が難しい場合） | `ForEach(0..<min(count, 5), id: \.self)` で index アクセス |

---

## 4. 画面別機能一覧

各画面で使える操作を一覧にする。

> 現状との差分（2026-10-02 にコードで確認）。この章は 2026-03 時点の画面構成で書かれており、現行の iOS アプリと次の点が異なる。`ContentView.swift` のタブは今日（TodayView）、さがす（BrowseTabView）、マイリスト（ListingListView の favoritesOnly）、設定（SettingsView）の4つである。DashboardView、DashboardFilteredListView、ScrapingConfigView は現行のコードに存在しない。成約タブ（TransactionTabView）は設定画面から開く。この章の該当箇所は旧構成の記述であり、現行の画面構成はコードで確認すること。

---

### 4.1 ログイン画面（LoginView）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | Google サインイン | ボタンタップ | Google アカウント選択 → Firebase Auth → ホワイトリストチェック |
| 2 | エラー表示 | 自動 | 許可されていないメールの場合にエラーメッセージを表示 |
| 3 | ローディング表示 | 自動 | サインイン処理中に ProgressView を表示 |
| 4 | 不正ログイン防止 | 自動 | 画面表示時にログイン済みだがホワイトリスト外の場合、自動サインアウト |

---

### 4.2 オンボーディング（WalkthroughView）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | ページ閲覧 | 左右スワイプ | 7ページのガイドをスワイプで移動 |
| 2 | 次へ進む | 「次へ」ボタン | 次のページへ遷移 |
| 3 | 前に戻る | 「戻る」ボタン | 前のページへ遷移（2ページ目以降で表示） |
| 4 | スキップ | 「スキップ」ボタン | 最終ページ以外で表示。即座に完了 |
| 5 | 開始 | 「はじめる」ボタン | 最終ページで表示。オンボーディング完了 |
| 6 | ページインジケーター | 自動 | 現在のページ位置をカプセルで表示 |
| 7 | アニメーション | 自動 | ページ切替時にコンテンツアニメーション |

---

### 4.2b ダッシュボード画面（DashboardView）— Phase1 追加

タブバーの先頭に「概況」タブとして配置し、マーケット全体の状況を表示する。

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | マーケット概況 | 自動/タップ | 中古/新築の掲載数・平均価格・新着数・値上げ/値下げ件数をカード形式で表示。新着・値下げ・値上げカードはタップできる（件数 > 0 のとき chevron.right を表示）。タップで `DashboardFilteredListView` に遷移し該当物件を一覧表示。一覧内の物件タップで詳細（`ListingDetailPagerView`）に遷移 |
| 2 | スコア分布 | 自動 | 総合投資スコアのグレード分布（S/A/B/C/D）をバーチャートで表示 |
| 3 | 価格変動物件 | 自動 | 直近の価格変動があった物件を変動額の大きい順に最大10件表示。各物件を個別カードで表示。値上がりは `↑` オレンジ、値下がりは `↓` ブルーで表記。価格変動日を `(M/D)` 形式で括弧書き表示（`parsedPriceHistory` の直近エントリの日付）。タップで物件詳細画面（`ListingDetailPagerView`）に遷移 |
| 4 | エリア別 m²単価ランキング | 自動 | 区別の平均 m²単価をランキング形式で表示（物件数付き） |

---

### 4.2c 財務シミュレーションツール群（Phase1 追加）

物件詳細画面の「⑥ 月額支払いシミュレーション」セクション直後にボタン群を配置。各ボタンタップで Sheet 表示。

| # | ツール名 | ビュー | 詳細 |
|---|---------|--------|------|
| 1 | 購入諸費用 | PurchaseCostCalculatorView | 印紙税・登録免許税・仲介手数料・ローン関連費用・火災保険料・司法書士報酬・固定資産税精算金・不動産取得税を自動計算。新築/中古で仲介手数料の有無を自動切替。借入比率スライダー付き |
| 2 | 銀行比較 | BankComparisonView | 主要8銀行（住信SBI/auじぶん/PayPay/楽天/みずほ/三井住友/三菱UFJ/りそな）の変動金利・固定10年・全期間固定の月額返済額・総返済額を一覧比較。借入額・返済期間のスライダー付き |
| 3 | ローン減税 | MortgageTaxBenefitView | 住宅ローン減税の年別控除額と合計控除額を算出。新築（13年）/中古（10年）の自動判定。年収・金利スライダー付き |
| 4 | 賃貸 vs 購入 | RentVsBuyView | 賃貸と購入の総コストを任意の居住年数で比較。月額家賃・賃料上昇率・ローン金利・値上がり率を調整可能。売却時の物件価値・ローン残高を考慮した実質コストで判定 |
| 5 | リノベ費用 | RenovationEstimateView | フル/部分リノベーション項目を選択して概算費用レンジを表示。面積に応じた m²単価ベースの計算。物件取得総額の表示付き |

---

### 4.3 中古タブ / 新築タブ（ListingListView）

中古タブ（`propertyTypeFilter: "chuko"`）と新築タブ（`propertyTypeFilter: "shinchiku"`）は同一のViewを使用する。

#### 検索・表示

> パフォーマンス対策として、`@Query` に `#Predicate` を設定し DB レベルで物件種別・掲載状態をフィルタ（中古/新築/お気に入り各タブで必要な物件のみロード）。フィルタ＋ソート結果は `onChange(of:)` で検知した場合のみ非同期再計算（`Task` でスケジュールし連続変更時は前回をキャンセル）し、`@State cachedFiltered` にキャッシュ。MapTabView も同様に `filteredListings` をキャッシュ。

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | 物件名検索 | テキスト入力 | インクリメンタル検索。物件名でフィルタ。 |
| 2 | 検索クリア | クリアボタン | 検索テキストを空にする |
| 3 | 一覧表示 | 自動 | 物件をリスト形式で表示（サムネイル画像、物件名、価格、間取り、面積、徒歩、バッジ）。SUUMO 物件写真がある場合は外観写真を優先してカード左側に幅 100pt・高さ 75pt の固定サイズサムネイルとして表示（`TrimmedAsyncImage` で周囲の白余白を自動トリミング・`.fill` + クリップで高さを統一、外観写真がない場合は先頭画像にフォールバック） |
| 3a | スケルトンローディング | 自動 | 初回ロード中（`cachedFiltered` 空かつ `isInitialLoadComplete` 未完了）は 5 行のプレースホルダーカード（`SkeletonLoadingView`）とシマーアニメーションを表示 |
| 4 | 空状態 | 自動 | データなし時に「データを取得」ボタン付きの案内を表示 |
| 5 | フィルタ空状態 | 自動 | フィルタ条件に合う物件がない時に「フィルタをリセット」ボタンを表示 |

#### ソート

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 6 | 追加日（新しい順） | ソートメニュー選択 | デフォルト。`addedAt` 降順。`addedAt` は新規挿入時に `firstSeenAt`（サーバーサイドの初回検出日）から設定されるため、スキーマリセット後も正しい順序を維持 |
| 7 | 価格（安い順） | ソートメニュー選択 | `priceMan` 昇順 |
| 8 | 価格（高い順） | ソートメニュー選択 | `priceMan` 降順 |
| 9 | 徒歩（近い順） | ソートメニュー選択 | `walkMin` 昇順 |
| 10 | 広さ（広い順） | ソートメニュー選択 | `areaM2` 降順 |
| 10b | 総合スコア順 | ソートメニュー選択 | `listingScore` 降順。投資判断スコアの高い順 |

#### カード表示強化（Phase2）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 10c | 管理費・修繕積立金表示 | 自動 | カード5行目にデータがある場合のみ管理費・修繕積立金・月額合計を表示 |

#### フィルタ

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 11 | フィルタシート表示 | ツールバーボタン | フルスクリーンでフィルタ画面を表示 |
| 11b | クイックプリセット | チップタップ | フィルタシート上部にワンタップで条件設定できるプリセットチップ群（駅近5分以内/都心3区/城南エリア/3LDK 70m²+ 等） |
| 12 | フィルタリセット | リセットボタン | 全条件を初期値に戻す |

#### 物件操作

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 13 | 物件詳細表示 | 行タップ | フルスクリーンカバーでスワイプページャー（ListingDetailPagerView）を表示。1物件のみ生成し横スワイプで前後の物件に遷移 |
| 14 | いいね | 右スワイプ | いいね ON/OFF 切替 → Firestore 同期 |
| 14b | コンテキストメニュー | 長押し | クイックプレビュー（物件名・価格・面積・間取り・徒歩・住所）+ いいね/共有 |
| 15 | 詳細を開く | 左スワイプ | 詳細画面をフルスクリーンカバーで表示 |
| 15b | 住戸展開 | 展開トグルタップ | 同一マンション内に2件以上の住戸がある場合、住戸テーブル（間取り・面積・価格・階）を展開/折りたたみ |
| 15c | 住戸詳細表示 | 住戸行タップ | 展開テーブル内の住戸行をタップすると、その住戸の詳細画面をページャーで表示 |

#### 比較機能

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 16 | 比較モード開始 | ツールバーボタン | チェックボックス付きモードに切替 |
| 17 | 物件選択 | チェックボックスタップ | 最大4件まで選択（5件目は選択不可） |
| 18 | 比較画面表示 | 「比較する」ボタン | 2件以上選択時に有効。ComparisonView を Sheet で表示 |
| 19 | 比較モード終了 | 「キャンセル」ボタン | 選択をクリアして通常モードに戻る |

#### データ更新

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 20 | 手動更新 | Pull-to-refresh | JSON URL から最新データを取得して SwiftData を更新 |
| 21 | 更新中表示 | 自動 | 更新中にバナーで表示 |
| 22 | エラー表示 | エラーボタンタップ | データ取得エラーの詳細をアラートで表示 |

---

### 4.4 お気に入りタブ（ListingListView favoritesOnly）

中古タブ/新築タブの全機能に加えて、次の機能がある。

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | 掲載終了フィルタ | チップタップ | 「すべて」「掲載中」「掲載終了」で切替 |
| 2 | CSV エクスポート | ツールバー ShareLink | お気に入り物件を CSV 形式で共有 |
| 3 | すべて表示に戻す | 「すべて表示」ボタン | 掲載終了フィルタを「すべて」に戻す |
| 4 | 編集モード | ツールバー EditButton | 複数選択モードに切替 |
| 5 | 一括いいね解除 | 編集モードで選択 → 解除ボタン | 選択した物件のいいねを一括解除。確認ダイアログ後に実行 |

---

### 4.5 フィルタシート（ListingFilterSheet）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | 価格下限設定 | プリセットチップ選択 | 下限価格をタップ選択（5,000〜14,000万円 / 指定なし） |
| 2 | 価格上限設定 | プリセットチップ選択 | 上限価格をタップ選択（6,000〜15,000万円 / 指定なし） |
| 3 | 価格未定物件を含む | トグル | 価格未定の新築物件を含めるかどうか |
| 4 | 坪単価下限設定 | プリセットチップ選択 | 下限坪単価をタップ選択（200〜450万円/坪 / 指定なし） |
| 5 | 坪単価上限設定 | プリセットチップ選択 | 上限坪単価をタップ選択（250〜500万円/坪 / 指定なし） |
| 6 | 間取り選択 | チップ複数選択 | 1K, 1LDK, 2LDK, 3LDK 等をタップで ON/OFF |
| 7 | 駅徒歩上限 | プリセットチップ選択 | 駅徒歩上限をタップ選択（3 / 5 / 7 / 10 / 15 / 20分以内 / 指定なし） |
| 8 | 専有面積下限 | プリセットチップ選択 | 面積下限をタップ選択（45〜80㎡以上 / 指定なし） |
| 9 | 区選択 | グリッドタップ | 東京23区をタップで ON/OFF |
| 10 | 権利形態選択 | チップタップ | 所有権 / 定期借地を選択 |
| 11 | 物件種別選択 | チップタップ | すべて / 中古のみ / 新築のみ |
| 12 | フィルタ適用 | 適用ボタン | 現在のフィルタ条件で一覧をフィルタ |
| 13 | フィルタリセット | リセットボタン | 全条件を初期値に戻す |
| 14 | キャンセル | 閉じるボタン | フィルタ変更を破棄して閉じる |
| 15 | アコーディオン展開 | セクションヘッダータップ | 各フィルタセクションの展開/折りたたみ。値が設定されたセクションは初回表示時に自動展開 |
| 16 | セクション個別クリア | ×ボタン | 値が設定されたセクションのヘッダーに×ボタンを表示。タップでそのセクションのみリセット |
| 17 | アクティブフィルタ数表示 | 自動 | ナビゲーションタイトルにアクティブなフィルタセクション数をバッジ表示（例: 「フィルタ (3)」） |
| 18 | テンプレート保存 | テンプレートメニュー → 「現在の条件を保存…」 | 現在のフィルタ条件に名前を付けて保存（最大5件。フィルタ未設定時・上限到達時は無効） |
| 19 | テンプレート適用 | テンプレートメニュー → テンプレート名タップ | 保存済みテンプレートのフィルタ条件を即座に反映 |
| 20 | テンプレートリネーム | テンプレートメニュー → 「名前を変更…」 → テンプレート選択 | テンプレート名を変更 |
| 21 | テンプレート削除 | テンプレートメニュー → 「削除…」 → テンプレート選択 | テンプレートを個別に削除 |

---

### 4.6 物件詳細画面（ListingDetailView / ListingDetailPagerView）

#### スワイプページャー

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 0a | 物件切替 | 左右スワイプ | 横スワイプで前後の物件に遷移。現在の1物件のみ ListingDetailView を生成し `.id()` で切替。DragGesture の方向判定で縦スクロールと競合回避 |
| 0b | ページ移動 | インジケーターの矢印タップ | 前後の物件に移動（先頭/末尾では無効化） |
| 0c | 位置確認 | 自動 | 画面下部フローティングカプセルに「3 / 15」形式で現在位置を表示 |

#### ヘッダー操作

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | 閉じる | ツールバーボタン | Sheet を閉じる |
| 2 | 共有 | ツールバー ShareLink | 物件 URL を共有 |
| 3 | いいね | ツールバーハートボタン | いいね ON/OFF → Firestore 同期 |
| 4 | キーボード非表示 | 画面タップ | 内見メモオーバーレイ内のコメント入力中にキーボードを閉じる |
| 4b | セクションジャンプ | セクションナビバーチップタップ | ツールバー直下の横スクロールチップ（物件情報・ローン・通勤・評価・シミュレーション・相場・人口・ハザード）をタップすると該当セクションへスクロール。データ有無に応じてチップの表示/非表示を切り替え |

#### 掲載状態

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 5 | 掲載終了バナー | 自動 | `isDelisted` 時に警告バナーを表示 |

#### 住所・地図

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 6 | Google Maps で開く | 住所タップ | Google Maps アプリ（またはブラウザ）で住所を検索 |

#### 内見メモ（オーバーレイ）

物件詳細画面にはカメラ＋コメントアイコンのコンパクトボタンのみ表示。タップで内見メモオーバーレイ（`.sheet` / `.medium` + `.large` detents）を開く。オーバーレイ内でコメント・写真を操作する。

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 6b | 内見メモを開く | コンパクトボタンタップ | 写真件数・コメント件数付きアイコンボタン → オーバーレイシートを表示 |
| 7 | コメント投稿 | テキスト入力 + 送信ボタン | オーバーレイ内でコメントを追加 → Firestore 同期 |
| 8 | コメント編集 | 編集ボタン | オーバーレイ内で既存コメントのテキストを編集モードに → 更新 |
| 9 | コメント削除 | 削除ボタン | 確認ダイアログ表示 → 削除 → Firestore 同期 |
| 10 | 編集キャンセル | キャンセルボタン | 編集モードを解除してテキストを元に戻す |
| 11 | 写真撮影 | カメラボタン | オーバーレイ内でカメラを起動して撮影 → ローカル保存 + Firebase Storage アップロード |
| 12 | ライブラリから選択 | フォトライブラリボタン | オーバーレイ内で PhotosPicker で画像選択 → 保存 + アップロード |
| 13 | サムネイル表示 | 横スクロール | 保存済み写真のサムネイルを横スクロールで一覧 |
| 14 | フルスクリーン表示 | サムネイルタップ | 写真をフルスクリーンで表示（スワイプで切替） |
| 15 | 写真削除 | サムネイル右上の×ボタン | 確認ダイアログ → ローカル + クラウドから削除 |
| 16 | アップロード状態表示 | 自動 | アップロード中は ProgressView、完了後はクラウドアイコン表示 |
| 17 | 投稿者名表示 | 自動 | 他ユーザーの写真には投稿者名を表示 |

#### 間取り図

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 17-b | 物件画像ギャラリー | 閲覧 | `hasFloorPlanImages \|\| hasSuumoImages` の場合のみ。間取り図を先頭に、SUUMO 物件写真（外観・リビング・キッチン・浴室等）を後続に配置した統合横スクロール。各画像にラベル表示。サムネイルは白余白を自動トリミングして画像コンテンツを最大化。Firebase Storage 経由で掲載終了後も永続表示可能 |
| 17-c | フルスクリーン表示 | 画像タップ | 画像をフルスクリーンで表示。横スワイプで前後の画像に移動可能（TabView ページング）。ページインジケーター・画像ラベル・枚数カウンター表示。白余白は自動トリミング済み。隣接画像を先読みしてスワイプ時の表示待ちを減らす |
| 17-d | 画像コピー | 長押し / ボタン | サムネイル・フルスクリーンともに長押し（`.contextMenu`）で「画像をコピー」「共有…」メニューを表示。コピーは `UIPasteboard.general.image` に設定。フルスクリーンではツールバー右上にもコピーボタンを常設。コピー完了時にオーバーレイフィードバックを表示（1.5秒後に自動非表示） |

#### 物件基本情報

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 18 | 価格表示 | 閲覧 | 万円表示。新築は価格帯（○万〜○万） |
| 18b | 平米単価表示 | 閲覧 | 価格÷面積（万円/㎡）。価格または面積が未設定の場合は「—」 |
| 18c | 坪単価表示 | 閲覧 | 平米単価×3.30578（万円/坪）。価格または面積が未設定の場合は「—」 |
| 19 | 間取り表示 | 閲覧 | 例: "3LDK"、新築は範囲 |
| 20 | 面積表示 | 閲覧 | ○㎡。新築は範囲（○〜○㎡） |
| 21 | 築年表示 | 閲覧 | 築年月 + 築○年の計算表示 |
| 22 | 階数表示 | 閲覧 | ○階 / ○階建て |
| 23 | 権利形態表示 | 閲覧 | 所有権 / 定期借地 |
| 24 | 総戸数表示 | 閲覧 | ○戸 |
| 24a | 向き表示 | 閲覧 | 方角（例: 南、北西） |
| 24b | バルコニー面積表示 | 閲覧 | ○㎡ |
| 24c | 用途地域表示 | 閲覧 | 例: 商業地域 |
| 24d | 駐車場表示 | 閲覧 | 例: 空有 月額20,000円〜25,000円 |
| 24e | 施工会社表示 | 閲覧 | 例: 大林組 |
| 24f | 修繕積立基金表示 | 閲覧 | 万円または円表示 |
| 24g | 引渡時期表示（中古） | 閲覧 | 中古の引渡可能時期（例: 即引渡可） |
| 24h | 特徴タグ表示 | 閲覧 | FlowLayout でチップ表示（例: 駅徒歩5分以内、2沿線以上利用可） |
| 25 | 引渡時期表示（新築） | 閲覧 | 新築のみ。例: "2027年9月上旬予定" |
| 26 | 月額支払い表示 | 閲覧 | 中古のみ。ローン条件での月額返済額を自動計算 |

#### 通勤時間セクション

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 27 | 通勤時間表示 | 閲覧 | Playground / M3Career への所要時間をバッジ表示 |
| 28 | Google Maps で経路確認 | バッジタップ | 物件→目的地の公共交通機関ルートを Google Maps で表示 |
| 29 | 通勤時間計算 | 「通勤時間を計算する」ボタン | MKDirections で計算 → キャッシュ保存。ボタン押下時に触覚フィードバック + ProgressView でローディング表示。計算完了時に成功/警告の触覚フィードバック |
| 29b | 通勤時間再検索 | 「正確な経路を再検索」ボタン | フォールバック概算（経路情報取得不可）の場合に表示。再計算を実行しローディング表示 |
| 30 | 複数駅展開 | セクションタップ | 複数最寄り駅がある場合にアコーディオン展開。各駅は路線名（caption・secondary）＋駅名（primary）＋徒歩バッジ（caption・右寄せ）の構造化レイアウトで表示。`stationLine` のパースは `／` `/` 区切りで分割し、路線名のみのセグメント（括弧・徒歩情報なし＆「線」を含む）は次のセグメント（駅名＋徒歩）とマージして1駅として扱う |

#### 住まいサーフィン評価セクション

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 31 | 沖式儲かる確率 | 閲覧 | ○% 表示 |
| 32 | 沖式中古時価 | 閲覧 | 70㎡換算の時価（万円） |
| 33 | m²割安額 | 閲覧 | 万円/㎡、割安/適正/割高の判定 |
| 34 | 中古値上がり率 | 閲覧 | ○% 表示 |
| 35 | 駅ランキング | 閲覧 | 例: "3/12" |
| 36 | 区ランキング | 閲覧 | 例: "8/45" |
| 37 | お気に入りスコア | 閲覧 | 点数表示 |
| 38 | 購入判定 | 閲覧 | バッジ表示（例: "購入が望ましい"） |
| 39 | レーダーチャート | 閲覧 | 6軸レーダーチャートで偏差値を視覚化 |
| 40 | 住まいサーフィンページを開く | リンクタップ | アプリ内 Safari で住まいサーフィンの物件ページを表示 |

#### 値上がりシミュレーションセクション

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 41 | 予測価格チャート | 閲覧 | 楽観/標準/悲観 × 5年後・10年後のバーチャート |
| 42 | 含み益チャート | 閲覧 | 予測価格 − ローン残高のバーチャート |
| 43 | ローン残高表示 | 閲覧 | 5年後・10年後の残債 |

#### 成約相場セクション（MarketDataSectionView）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 44 | 相場乖離率カード | 閲覧 | 掲載価格 vs 類似物件成約相場の乖離率・差額を表示 |
| 45 | マッチ精度バッジ | 閲覧 | 比較データのマッチ精度（高/中/低）をバッジ表示 |
| 46 | エリア相場グリッド | 閲覧 | 類似物件相場、区トレンド、前年比を3カラムで表示 |
| 47 | 駅レベル比較 | 閲覧 | 駅圏相場・物件との乖離率・トレンド・前年比を表示。乖離率はバックエンド算出値を優先し、未算出の場合は iOS 側で `priceMan × 10000 / areaM2 ÷ 駅圏中央値` をフォールバック計算 |
| 48 | 同一マンション成約事例 | 閲覧 | 同一マンション候補の成約事例を間取り別サマリーで表示。各間取り（2LDK, 3LDK等）ごとに平均成約価格・平均m²単価・件数を集約表示し、閲覧中物件と同じ間取りは「同間取り」バッジ付きで先頭にハイライト表示。DisclosureGroup で展開すると個別成約明細（時期・面積・価格・m²単価・信頼度バッジ）を確認可能。信頼度は high（高）/medium（中）/low（低）の3段階で色分けバッジ表示 |
| 48b | マンションレビュー | 閲覧 | `parsedMansionReviewData` がある場合に表示。マンション偏差値（大数字・色分け）・推定適正価格・騰落率のサマリーカード、推定m²単価・坪単価、中古販売履歴件数、マンションレビューへのリンクを表示 |
| 49 | 四半期推移チャート | 閲覧 | 区（5年分）・駅の m²単価の四半期推移を折れ線チャートで表示。X軸は年ラベルのみ（Q1位置）、四半期ごとのデータポイントで推移を描画 |

#### エリア人口動態セクション（PopulationSectionView）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 50 | 人口・世帯数・高齢化率サマリー | 閲覧 | 区の人口、世帯数、高齢化率、前年比、5年変動を3カラムグリッドで表示。高齢化率は `hasAgingData` の場合のみ表示（25%以上: オレンジ、20%以上: デフォルト、20%未満: ポジティブカラー） |
| 51 | 人口推移チャート | 閲覧 | 区の人口推移を折れ線+エリアチャートで表示（monotone 補間）。AreaMark は yMin 基準の明示的ベースライン、Y軸ラベルは stride に応じた動的フォーマット（≥1→整数万、≥0.1→小数1桁万、その他→小数2桁万）でコンパクト表示 |
| 52 | 高齢化率推移チャート | 閲覧 | `hasAgingData` の場合のみ。全国平均（灰色破線）・23区平均（青破線）・当該区（アクセントカラー実線）の3本折れ線を国勢調査5年間隔（2000-2020）で表示。Y軸は%表示、凡例をチャート下部に配置 |

#### ハザード情報セクション

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 52 | ハザードチップ表示 | 閲覧 | 洪水、内水、土砂、高潮、津波、液状化の各リスクレベルをチップで表示 |
| 53 | ハザードガイド | DisclosureGroup タップ | 各ハザードの意味・注意点の解説を展開/折りたたみ |

#### 周辺物件セクション

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 54 | 周辺物件一覧 | セクションヘッダータップ | アコーディオンで展開/折りたたみ |
| 55 | 周辺物件詳細 | 行タップ | アプリ内 Safari で住まいサーフィンの物件ページを表示 |

#### 価格判定セクション

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 56 | 価格判定一覧 | セクションヘッダータップ | アコーディオンで展開/折りたたみ |

#### 類似物件セクション（Phase 4）

同一区・同一物件種別（中古/新築）・価格帯（±20%）の類似物件を最大3件表示。`.task` で `FetchDescriptor`（`fetchLimit: 20`、価格帯・種別プレディケート）による遅延フェッチで必要データのみ取得し、`Listing.extractWardFromAddress` で区名フィルタ。掲載終了物件・自物件は除外。

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 56-b | 類似物件一覧 | 閲覧 | 類似物件が存在する場合のみ表示。物件名・価格・面積・間取り・徒歩をカード形式で表示 |
| 56-c | 類似物件詳細 | 行タップ | `.fullScreenCover(item:)` で ListingDetailView をフルスクリーンカバー表示 |

#### AI 相談セクション（意思決定型プロンプト）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 56-d | 買い手条件設定 | ボタンタップ | `BuyerProfileSheet` をシート表示。家族構成・世帯年収・自己資金・借入条件・金利タイプ・月額上限・働き方・子ども予定・住み替え理由・売却/賃貸方針・重視ポイントを入力。UserDefaults に永続化。未設定時はオレンジ色で警告表示、設定済みは緑色で反映済みを表示 |
| 57 | Markdown コピー | ボタンタップ | `Listing.toMarkdown()` で物件情報を構造化 Markdown に変換し、クリップボードにコピー。Markdown は「事実情報」と「参考情報」を `---` で分離。参考情報にはデータソース・算出根拠を併記。間取り図 URL も含む |
| 57-b | 間取り図コピー | ボタンタップ | `hasFloorPlanImages` の場合のみ表示。先頭の間取り図画像を `TrimmedImageCache` から取得し `UIPasteboard.general.image` にコピー |
| 58 | ChatGPT で相談 | ボタンタップ | `toAIConsultationPrompt(otherCandidates:buyerProfile:)` で意思決定型プロンプトを生成しクリップボードにコピー。`chatgpt://` でアプリ直接起動（未インストール時は `chatgpt.com` にフォールバック）。プロンプトは以下を含む: 買い手条件テーブル、出口試算要求（7年・10年・13年×3シナリオ＋前提条件明示）、価格妥当性2軸評価（区中央値・同駅同条件±8年±10㎡）、家族計画整合チェック、ハザード自治体上書き確認、比較物件フルリサーチ、情報源重みづけルール、未確認情報明示ルール、必須出力フォーマット13項目、AIフィードバック要求。ロゴ: `logo-chatgpt` |
| 59 | Gemini で相談 | ボタンタップ | プロンプトをクリップボードにコピー。`googlegemini://` → `googleapp://robin` → `gemini.google.com/app` の順に `UIApplication.open` の completion handler で成否判定し自動フォールバック。`LSApplicationQueriesSchemes` に `googlegemini` / `googleapp` を登録。ロゴ: `logo-gemini` |
| 60 | Claude で相談 | ボタンタップ | プロンプトをクリップボードにコピー。`claude://` でアプリを直接起動（未インストール時は `claude.ai/new` にフォールバック）。`LSApplicationQueriesSchemes` に `claude` を登録。ロゴ: `logo-claude` |

#### 外部リンク

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 61 | SUUMO/HOME'S ページ | リンクタップ | アプリ内 Safari で物件詳細ページを表示 |
| 62 | 住まいサーフィンページ | リンクタップ | アプリ内 Safari で住まいサーフィンページを表示 |

---

### 4.7 物件比較画面（ComparisonView）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | 閉じる | ツールバーボタン | Sheet を閉じる |
| 2 | AI で比較 | ツールバーボタン | AIComparisonSheet を表示。選択した全物件の詳細情報を含む比較プロンプトを生成し、ChatGPT / Gemini / Claude で比較評価を依頼できる |
| 3 | PDF 出力 | ツールバーボタン | A4 比較シートを PDF 生成し、共有シートで保存・共有 |
| 4 | 横スクロール比較 | 横スワイプ | 2〜4件の物件を横並びテーブルで比較。Grid レイアウトにより行高が全列で自動同期 |
| 5 | 基本情報比較 | 閲覧 | 価格、間取り、面積、築年、徒歩、階数、総戸数、権利形態 |
| 6 | 住まいサーフィン評価比較 | 閲覧 | 儲かる確率、値上がり率、購入判定（データがある場合） |
| 7 | 成約相場比較 | 閲覧 | 相場データがある物件の比較（データがある場合） |
| 8 | 人口動態比較 | 閲覧 | 人口データがある物件の比較（データがある場合） |
| 9 | 件数不足表示 | 自動 | 2件未満の場合に ContentUnavailableView を表示 |

#### 4.7.1 AI 比較シート（AIComparisonSheet）

ComparisonView のツールバー「AI で比較」ボタンから表示されるシート。選択した複数物件を対等に比較する AI プロンプトを生成し、生成 AI サービスに渡す。

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | 比較対象一覧 | 閲覧 | 選択された物件の名前・価格・面積・最寄駅を番号付きリストで表示 |
| 2 | 買い手条件設定 | ボタンタップ | BuyerProfileSheet を表示。設定済みの場合はプロンプトに自動反映 |
| 3 | Markdown コピー | ボタンタップ | 全物件の物件情報 Markdown をクリップボードにコピー（プロンプト指示なし） |
| 4 | 間取り図まとめコピー | ボタンタップ | 間取り図がある物件の間取り図を物件名ラベル付きで横並びに1枚の合成画像として `UIPasteboard.general.image` にコピー。AIアプリが複数画像ペーストに対応しないため、`UIGraphicsImageRenderer` で合成。シート表示時に非同期で各物件の先頭間取り図を `TrimmedImageCache` 経由で取得。読み込み中は ProgressView を表示。間取り図がある物件がない場合はボタン非表示 |
| 5 | ChatGPT で比較 | ボタンタップ | `Listing.toAIComparisonPrompt(listings:buyerProfile:)` で全物件対等比較プロンプトを生成しクリップボードにコピー、ChatGPT を起動 |
| 6 | Gemini で比較 | ボタンタップ | 同上、Gemini を起動 |
| 7 | Claude で比較 | ボタンタップ | 同上、Claude を起動 |

AI 比較プロンプトは、全物件を対等に扱い、各物件の `toMarkdown()` フル情報 + 住まいサーフィンシミュレーションデータを含む。出力フォーマットは総合ランキング・横断比較表（価格妥当性・資産性・生活利便性・リスク・総合評価）・各物件個別分析（妥当価格レンジ・買付上限・出口試算3シナリオ）・物件間の決定的差異・仲介確認質問・未確認事項。自律リサーチ指示（各物件のマンション名・住所・成約相場・ハザード検索）を含む。

---

### 4.8 地図タブ（MapTabView）

#### 地図操作

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | 地図閲覧 | ピンチ・パン | MapKit で自由にズーム・スクロール |
| 2 | 現在地表示 | 左下ボタンタップ | CLLocationManager で現在地に移動・中心表示 |
| 3 | 物件ピン表示 | 自動 | 全物件を地図上にピンで表示 |
| 3b | ピンクラスタリング | 自動 | ズームアウト時に近接ピンをクラスターに集約。クラスター表示は件数バッジ |
| 4 | ピン色分け | 自動 | 中古（青●）/ 新築（緑●）/ いいね済み（赤いハート） |

#### 物件操作

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 5 | 物件ポップアップ | ピンタップ | 物件概要（名前、価格、面積等）+ いいねボタンのポップアップ |
| 6 | 物件詳細表示 | ポップアップタップ | フルスクリーンカバーで物件詳細画面を表示 |
| 7 | 地図からいいね | ポップアップのハートタップ | いいね ON/OFF → Firestore 同期 |

#### ツールバー

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 8 | データ更新 | 更新ボタン | JSON URL から最新データを取得 |
| 9 | ハザードマップ表示 | ハザードボタン | ハザードレイヤー設定シートを表示 |
| 10 | フィルタ | フィルタボタン | フィルタシートを表示 |

#### ハザードマップオーバーレイ（シート内）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 11 | 洪水浸水想定 | トグル ON/OFF | 国土地理院タイルを地図に重畳 |
| 12 | 内水浸水想定 | トグル ON/OFF | 同上 |
| 13 | 土砂災害警戒区域 | トグル ON/OFF | 同上 |
| 14 | 高潮浸水想定 | トグル ON/OFF | 同上 |
| 15 | 津波浸水想定 | トグル ON/OFF | 同上 |
| 16 | 液状化（地形分類） | トグル ON/OFF | 治水地形分類図（`lcmfc2`）タイルを重畳。旧河道・後背湿地等の地形からリスクを判読 |
| 17 | 浸水継続時間 | トグル ON/OFF | 同上 |
| 18 | 家屋倒壊（氾濫流） | トグル ON/OFF | 同上 |
| 19 | 家屋倒壊（河岸侵食） | トグル ON/OFF | 同上 |
| 20 | 揺れやすさ（地形分類） | トグル ON/OFF | 治水地形分類図（`lcmfc2`）タイルを重畳。地形から揺れやすさを判読 |
| 21 | 各レイヤー情報 | インフォボタン | 各ハザードレイヤーの解説をシートで表示 |

#### 東京都地域危険度オーバーレイ（シート内）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 22 | 建物倒壊危険度 | トグル ON/OFF | GeoJSON → MKPolygon でランク1-5色分け表示 |
| 23 | 火災危険度 | トグル ON/OFF | 同上 |
| 24 | 総合危険度 | トグル ON/OFF | 同上 |
| 25 | 各レイヤー情報 | インフォボタン | 各危険度レイヤーの解説をシートで表示 |

#### プリセット操作

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 26 | 重要3項目 ON | ボタン | 洪水 + 液状化（地形分類） + 建物倒壊 + 淡色地図を一括 ON |
| 27 | すべて ON | ボタン | 全ハザード・地域危険度レイヤーを ON |
| 28 | すべて OFF | ボタン | 全レイヤーを OFF |
| 29 | 淡色地図 | トグル ON/OFF | ベースマップを淡色に切替（ハザードを見やすく） |

#### エラー・状態表示

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 30 | 更新中オーバーレイ | 自動 | データ更新中に ProgressView + Material オーバーレイ |
| 31 | エラーオーバーレイ | タップ | データ取得エラー表示 → タップでアラート（再取得 or 閉じる） |
| 32 | ジオコーディング失敗 | 自動 | 座標変換に失敗した件数を表示 |

---

### 4.9 設定画面（SettingsView）

#### 通知設定

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | 通知許可確認 | 自動 | 通知の許可状態を表示 |
| 2 | 通知を有効にする | ボタン | 端末の通知設定画面に遷移 |
| 3 | 通知を許可する | ボタン | 通知許可を初回リクエスト |
| 4 | 通知回数設定 | Stepper | 1日の通知回数を0〜6回で設定 |
| 5 | 通知時刻設定 | DatePicker | 通知回数分の配信時刻を個別設定 |
| 6 | コメント通知 | トグル ON/OFF | 新しいコメントのローカル通知を有効/無効 |

#### データ管理

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 6a | 最近見た物件 | NavigationLink | RecentlyViewedListView を表示。viewedAt でソート、最大30件。タップで物件詳細をフルスクリーンカバー表示 |
| 7 | フルリフレッシュ | ボタン | 確認ダイアログ → ETag クリア + 全件再取得 |
| 8 | 最終更新時刻 | 閲覧 | 前回データ取得の日時を表示 |

#### カスタム URL 設定

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 9 | カスタム URL 展開 | DisclosureGroup タップ | 詳細 URL 設定セクションの展開/折りたたみ |
| 10 | 中古 JSON URL 入力 | テキストフィールド | 中古物件 JSON の URL を入力 |
| 11 | 新築 JSON URL 入力 | テキストフィールド | 新築物件 JSON の URL を入力 |
| 12 | URL 保存 | 保存ボタン | 入力した URL を UserDefaults に保存 → 確認アラート |
| 13 | デフォルト URL に戻す | ボタン | 確認ダイアログ → URL をデフォルトにリセット |
| 14 | カスタム URL 説明 | インフォボタン | カスタム URL の使い方をアラートで表示 |

#### 通勤先設定

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 14a | 通勤先設定 | NavigationLink | CommuteDestinationSettingsView を表示。通勤先の追加（住所ジオコーディング）・削除・デフォルト復元。最大3箇所まで |

#### スクレイピング管理

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 15 | スクレイピング条件 | ボタン | ScrapingConfigView を Sheet で表示 |
| 16 | スクレイピングログ | ボタン | ScrapingLogView を Sheet で表示 |

#### アカウント

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 17 | ユーザー情報表示 | 閲覧 | 名前・メールアドレスを表示 |
| 18 | ログアウト | ボタン | 確認ダイアログ → Firebase Auth サインアウト |

#### その他

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 19 | 使い方ガイド | ボタン | WalkthroughView を fullScreenCover で再表示 |

---

### 4.10 スクレイピング条件設定画面（ScrapingConfigView）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | 閉じる | ツールバーボタン | Sheet を閉じる |
| 2 | 保存 | ツールバーボタン | 条件を Firestore に保存 → 成功アラート → 閉じる |
| 3 | 価格下限入力 | テキストフィールド | 数値入力（万円） |
| 4 | 価格上限入力 | テキストフィールド | 数値入力（万円） |
| 5 | 面積下限入力 | テキストフィールド | 数値入力（㎡） |
| 6 | 面積上限入力 | テキストフィールド | 数値入力（㎡、任意） |
| 7 | 駅徒歩設定 | Stepper | 1〜20分で設定 |
| 8 | 竣工年設定 | Picker | 年を選択 |
| 9 | 総戸数設定 | テキストフィールド | 数値入力 |
| 10 | 間取り選択 | チップタップ | 1LDK系, 2LDK系, 3LDK系 等を ON/OFF |
| 10b | 対象駅選択 | チップタップ | `ScrapingConfigMetadata.json` の駅グループ（千代田区・中央区・港区・半蔵門線・有楽町線）を ON/OFF + テキストフィールドで任意追加 |
| 11 | 路線選択 | チップタップ | JR, 東京メトロ, 都営, 東急, 京急 等を ON/OFF |
| 12 | 保存成功アラート | 自動 | 保存成功時に「保存しました」アラート |
| 13 | 保存失敗アラート | 自動 | 保存失敗時にエラーメッセージアラート |
| 14 | 未認証表示 | 自動 | Firebase 未認証の場合にログイン案内を表示 |
| 15 | ローディング | 自動 | 保存中にツールバーに ProgressView を表示 |
| 16 | 最新設定の先読み | 自動 | 設定画面の「スクレイピング条件」タップ時に Firestore を強制再取得し、取得完了後に Sheet を表示（古い設定の編集を防止） |

---

### 4.11 スクレイピングログ画面（ScrapingLogView）

| # | 機能 | 操作 | 詳細 |
|---|------|------|------|
| 1 | 閉じる | ツールバーボタン | Sheet を閉じる |
| 2 | ログ閲覧 | 閲覧 | 最新パイプライン実行のステータス・タイムスタンプ・ログ本文 |
| 3 | ログ展開/折りたたみ | 「ログ本文」ボタン | ログテキストの表示/非表示を切替 |
| 4 | ログ全文コピー | コピーボタン | ログ全文をクリップボードにコピー（ツールバー + 本文内の2箇所） |
| 5 | コピー完了表示 | 自動 | コピー後2秒間「コピーしました」を表示 |
| 6 | Pull-to-refresh | 下に引く | Firestore から最新ログを再取得 |
| 7 | 再試行 | ボタン | 取得失敗時に再試行 |
| 8 | ローディング | 自動 | 読み込み中に ProgressView を表示 |
| 9 | 切り詰め通知 | 自動 | ログが切り詰められている場合に警告バッジ表示 |
| 10 | ステータス色分け | 自動 | ログのステータスに応じて色分け表示 |

---

### 4.12 グローバル機能（画面横断）

| # | 機能 | 画面 | 詳細 |
|---|------|------|------|
| 1 | オフラインバナー | 全タブ | ネットワーク未接続時に「オフラインです」バナーを画面上部に表示 |
| 2 | タブ切替 | 全体 | 中古 / 新築 / 地図 / お気に入り / 設定 の5タブ |
| 3 | プッシュ通知ハンドリング | 全体 | FCM 通知タップ → 中古タブに遷移 |
| 4 | コメント通知ハンドリング | 全体 | コメント通知タップ → 該当物件の詳細画面を表示 |
| 4b | Spotlight ディープリンク（p6-02） | 全体 | Spotlight 検索でいいね済み物件をタップ → アプリ起動 → 該当物件の詳細画面を Sheet 表示。`onContinueUserActivity(CSSearchableItemActionType)` で URL を受け取り、SwiftData から該当物件を取得 |
| 5 | 自動データ更新 | 全体 | フォアグラウンド復帰時に15分経過で自動更新（物件）/ 1時間経過で自動更新（成約実績） |
| 5-b | 成約実績自動取得 | 全体 | 初回起動時 or SwiftData が空（スキーマリセット後）の場合に自動取得。`lastFetchedAt` が UserDefaults に残っていても、SwiftData の `TransactionRecord` 件数 = 0 なら再取得を実行 |
| 6 | バックグラウンド更新 | 全体 | BGAppRefreshTask で定期的に JSON 取得 → 新着検出 → ローカル通知 |
| 7 | フィルタ独立管理 | 中古・新築・地図・お気に入り | FilterStore をタブごとに独立保持（OOUI: タブ間で干渉しない） |
| 7b | フィルタテンプレート共有 | 中古・新築・地図・お気に入り | FilterTemplateStore をアプリレベルで環境注入し、全タブで同じテンプレートリストを共有（最大5件、UserDefaults 永続化） |
| 8 | Firestore アノテーション同期 | 全体 | アプリ起動時に Firestore からいいね・コメント・写真メタを取得 |
| 9 | 保存エラーアラート | 全体 | SwiftData 保存エラー時にアラートを表示 |
| 10 | キーボード自動非表示 | 全体 | タブ切替時にキーボードを自動で閉じる |

---

### 4.13 機能数サマリー

| 画面 | 機能数 |
|------|--------|
| ログイン | 4 |
| オンボーディング | 7 |
| 中古/新築一覧 | 22 |
| お気に入り | 22 + 3 = 25 |
| フィルタシート | 21 |
| 物件詳細 | 71 |
| 物件比較 | 15 |
| 地図 | 32 |
| 設定 | 20 |
| スクレイピング条件 | 15 |
| スクレイピングログ | 10 |
| グローバル | 10 |
| 合計 | 約240機能 |

## 5. スクレイピングツール仕様

> 現状との差分（2026-10-02 にコードで確認）。この章は 2026-03 時点のパイプラインで書かれており、現行のコードと次の点が異なる。新築のスクレイピングは2026-06に廃止され、`main.py` の `--property-type`、`scripts/run_scrape.sh`、`scripts/run_enrich.sh` は中古（chuko）だけを扱う。`suumo_shinchiku_scraper.py`、`shinchiku_detail_enricher.py`、`homes_shinchiku_scraper.py` は存在しない。`main.py --source all` の対象は suumo、homes、athome、rehouse、nomucom、stepon、livable の7ソースである。WF2 の enrich ジョブは `enrich-chuko-core`（`--tracks core`）と `enrich-chuko-mansion`（`--tracks mansion`）の2つで、住まいサーフィンは別ワークフロー `enrich-sumai.yml` が処理する。`run_enrich.sh` の Track G は HOME'S 画像（`floor_plan_enricher.py`）である。`send_push.py` は `scripts/` 配下にある。この章の新築に関する記述と 5.2 節の WF2 構成図は旧構成のものである。

### 5.1 データソース

| ソース | 種別 | URL パターン | 状態 |
|--------|------|-------------|------|
| SUUMO 中古 | 中古マンション | `suumo.jp/jj/bukken/ichiran/JJ012FC001/?ar=030&bs=011&ta=13&sc={ward_code}&kb={min}&kt={max}&mb={area}&et={walk}`（サーバーサイドフィルタ付き）。フィルタなし時は `suumo.jp/ms/chuko/tokyo/sc_{ward}/` | 有効 |
| SUUMO 新築 | 新築マンション | `suumo.jp/jj/bukken/ichiran/JJ011FC001/?ar=030&bs=010&ta=13` | 有効 |
| ~~HOME'S 中古~~ | 中古マンション | `homes.co.jp/mansion/chuko/tokyo/23ku/list/` | 無効（WAF により実用的な取得が困難） |
| ~~HOME'S 新築~~ | 新築マンション | `homes.co.jp/mansion/shinchiku/tokyo/list/` | 無効（同上） |
| 住まいサーフィン | 評価データ | `sumai-surfin.com`（ログイン必要） | 有効 |
| 国土地理院 | ハザードデータ | GSI タイル（`disaportaldata.gsi.go.jp`） | 有効 |
| 東京都 | 地域危険度 | GeoJSON（GitHub raw） | 有効 |

### 5.2 スクレイピングパイプライン

パイプラインは2つの GitHub Actions ワークフローに分離されている。WF1（Scrape Listings）がデータ取得を行い、WF2（Enrich & Report）が加工・レポート生成を行う。WF1 は 20-40分で完走するため 2時間スケジュールでキャンセルされない。WF2 は `cancel-in-progress: false` で、実行中のジョブは完了まで実行され、次の実行はキューで待機する（GitHub Actions はキューに1件のみ保持）。

#### WF1: Scrape Listings（`scripts/run_scrape.sh`）

```
中古 + 新築を並列スクレイピング
├── main.py --property-type chuko     → latest_raw.json  ─┐ 並列
└── main.py --property-type shinchiku → latest_shinchiku_raw.json ─┘
    ↓
変更検出: check_changes.py（変更なし → WF2 をスキップ）
    ↓
Artifact upload: latest_raw.json, latest_shinchiku_raw.json, metadata.json
※ git commit しない（生データは artifact 経由のみ）
```

#### WF2: Enrich & Report（4並列ジョブ + finalize）

各enrichジョブ内で全enricherを完全並列に実行する（`scripts/run_enrich.sh`）。各enricherは独自のファイルコピーで動作し、`merge_enrichments.py` でフィールドレベルにマージする。

```
Job 1: enrich-chuko / Job 2: enrich-shinchiku（同構造、並列実行）
   Phase 1: embed_geocode.py（geocode_cache から lat/lng 埋め込み、< 1min）
       ↓
   Phase 2: 全 enricher 完全並列（各 enricher が独自ファイルコピーで動作）
   ├── Track PREP: build_units_cache → merge_detail_cache（~15min）
   ├── Track A: sumai_surfin_enricher（~10-60min、律速）
   ├── Track B: geocode_cross_validator → hazard_enricher（~4min）
   ├── Track C: commute_enricher（~1min）
   ├── Track D: reinfolib_enricher（~1min）
   ├── Track E: estat_enricher（~1min）
   └── Track G: mansion_review_scraper（~5min、中古のみ）
       ↓
   Phase 3: merge_enrichments.py

Job 3: build-transaction-feed（完全独立、~15min）
   └── build_transaction_feed.py --quarters 20

Job 4: finalize（if: !cancelled()、一部ジョブ失敗でも実行）
   ├── merge_caches.py（geocode, sumai_surfin, manifest, station, reverse_geocode, building_units を union マージ）
   ├── upload_floor_plans.py（8並列で画像 DL+Firebase Storage アップロード、--max-time で時間制限付き）
   ├── scripts/finalize_helpers.py inject-new（is_new / is_new_building 注入）
   ├── scripts/finalize_helpers.py inject-investment（price_history / first_seen_at / competing_count / listing_score 注入）
   ├── build_map_viewer.py（中古+新築の地図生成）
   ├── geocode.py（キャッシュクリーンアップ）
   ├── convert_risk_geojson.py（初回のみ）
   ├── generate_report.py → Markdown レポート
   ├── scripts/finalize_helpers.py count-new（通知用件数算出）
   ├── send_push.py → FCM プッシュ通知（is_new / is_new_building フラグのカウントで新着件数・新規物件vs別部屋の内訳、price_history で価格変動を検出して通知本文に含める）
   ├── slack_notify.py → Slack 日次通知（1日1回 6:00〜10:00 JST。前回通知からの差分ベース。previous_slack.json でスナップショット管理）
   └── git commit & push
```

> 全 enricher を並列化しても安全な理由は、各 enricher が追加するフィールドに重複がないことにある（sumai_surfin: `ss_*`, hazard: `hazard_info`, commute: `commute_info`, reinfolib: `reinfolib_market_data`, estat: `estat_population_data`, mansion_review: `mansion_review_data`, units_cache: `total_units`, `direction`, `balcony_area_m2`, `parking`, `constructor`, `zoning`, `repair_fund_onetime`, `delivery_date`, `feature_tags` 等）。各 enricher が独自のファイルコピーで動作し、`merge_enrichments.py` がフィールドレベルで union マージするため競合なし。マージ時に `None` 値は無視する（後続 track ファイルの未設定フィールドで先行 track の値を上書きしない）。

> Phase1 で追加した投資判断支援 enrichment は、全 enricher 完了後の Phase 3 で次の順に実行する。
> 1. `inject_price_history(cur, prev)` — 前回比較で価格変動があった物件に `price_history` を追記（`report_utils.py`）
> 2. `inject_first_seen_at(cur, prev)` — 初回掲載検出日 `first_seen_at` を付与・継承（`report_utils.py`）
> 3. `inject_competing_count(listings)` — 同一マンション内の競合売出物件数 `competing_listings_count` を付与（`report_utils.py`）
> 4. `investment_enricher.py` — `price_fairness_score`、`resale_liquidity_score`、`listing_score` を算出・付与
> 5. `build_supply_trends.py` — 供給トレンドの日次スナップショットを `supply_trends.json` に蓄積（最大365日分）

> 障害許容は5層で構成する。(1) WF 分離により取得は常に完走する。(2) ジョブは `continue-on-error: true` で、中古が失敗しても新築は反映する。(3) 全 enricher を `|| true` でラップする。(4) マージは存在するファイルだけを対象にする。(5) finalize は `if: !cancelled()` で、部分データでもコミットする。

> キャッシュマージについて。中古/新築の各ジョブが独立更新した `geocode_cache.json`, `sumai_surfin_cache.json`, `floor_plan_storage_manifest.json`, `station_cache.json`, `reverse_geocode_cache.json`, `building_units.json` は、finalize ジョブで `merge_caches.py` により union マージされてからコミットされる。`building_units.json` のマージにより、物件詳細ページから取得した権利形態（所有権/定借）等の情報がリポジトリに蓄積される。

> ジオコーディングの最適化として、`geocode.py` は住所の早期フィルタ機能を持つ。他県住所（千葉・埼玉・神奈川等）や東京都多摩地域（八王子・町田・府中等）は Nominatim API 問い合わせ前にスキップし、不要な API コールと待機時間を削減する。

> ローカル実行用に `scripts/update_listings.sh` を維持している。全フェーズを直列で実行する旧来のパイプラインである。

> データ品質検証（Phase3）として、`scripts/validate_data.py` がパイプラインの最終段階で `latest.json` / `latest_shinchiku.json` の品質を検証する。必須フィールド欠損率（50%超でエラー、10%超で警告）、価格・面積の妥当性、0以下価格、URL 重複、identity_key 衝突、ジオコーディング率、住まいサーフィンマッチ率を報告する。エラー有無は `ValidationResult.has_errors` で判定する。`--previous` オプションで前回データとの件数変動（25%超で警告、50%超でエラー）を検出する。

> キャッシュ管理（Phase3）として、`scripts/cache_manager.py` が TTL に基づいてキャッシュをクリーンアップする。`geocode_cache.json`（90日）、`sumai_surfin_cache.json`（30日）、`station_cache.json`（180日）、`reverse_geocode_cache.json`（90日）の各エントリについて、`cached_at` / `fetched_at` / `timestamp` フィールドで期限切れを判定して削除する。`--stats` で統計を表示し、`--cleanup` で削除を実行する。

### 5.3 スクレイパー詳細

#### 5.3.1 SUUMO 中古（suumo_scraper.py）

| 項目 | 詳細 |
|------|------|
| パース対象 | `div.property_unit-content` / カセットレイアウト |
| 取得フィールド | name, price, address, station_line, walk_min, area_m2, layout, built_year, floor, ownership |
| 総戸数 | `building_units.json`（詳細ページキャッシュ）から取得 |
| 詳細ページパース | `parse_suumo_detail_html()` が HTML テーブルから direction（向き）、balcony_area_m2、parking、constructor（施工会社）、zoning（用途地域）、repair_fund_onetime（修繕積立基金）、delivery_date（引渡時期、中古の引渡可能時期）を抽出。JavaScript `gapSuumoPcForKr` オブジェクトから direction（muki）、feature_tags（tokuchoPickupList）を `_parse_js_gap_object()` で取得。direction は JS を優先し HTML でフォールバック、feature_tags は JS からのみ |
| フィルタ方式 | サーバーサイドフィルタ + ローカルフィルタの2段構成。`apply_filter=True` 時は SUUMO の JJ012FC001 エンドポイント（`/jj/bukken/ichiran/JJ012FC001/?sc={ward_code}&kb={price_min}&kt={price_max}&mb={area_min}&et={walk_max}`）でサーバー側で価格帯・面積・駅徒歩を絞り込んでからローカルで `apply_conditions` を適用。`mb`/`et` は SUUMO が受け付ける固定値のみ使用可（`_snap_mb` で切り捨て、`_snap_et` で切り上げ）。`SEARCH_FILTERS`（`cn`=築年数、`lc`=間取り）で追加パラメータを設定可能（空=制限なし）。`apply_filter=False` 時は従来の `/ms/chuko/tokyo/sc_XXX/` URL でフィルタなし取得。区コードは `SUUMO_23_WARD_SC_CODES`（JIS市区町村コード）で管理 |
| 徒歩パース | `parse_walk_min` は「徒歩N分」「歩N分」の両形式に対応 |
| 早期打ち切り | 連続20ページで新規通過0件の区はスキップ（`EARLY_EXIT_PAGES=20`）。サーバーサイドフィルタ（価格・面積・徒歩）で対象外物件が事前に除外されるため、早期打ち切りによる取りこぼしは大幅に少ない |
| 出力 | `SuumoListing` dataclass |

#### 5.3.2 ~~HOME'S 中古（homes_scraper.py）~~ — 現在無効

> 無効化の理由は次の通り。AWS WAF が GitHub Actions の IP を積極的にブロックし、1ページあたり最大7分のリトライが発生。30ページ処理しても通過0件という状況が続いたため無効化。コードは `--source homes` / `--source both` で再有効化可能。

#### 5.3.3 SUUMO 新築（suumo_shinchiku_scraper.py + shinchiku_detail_enricher.py）

| 項目 | 詳細 |
|------|------|
| 一覧取得フィールド | 基本情報 + 価格レンジ、面積レンジ、間取りレンジ、引渡時期、権利形態（ownership） |
| 詳細ページ enrichment | `shinchiku_detail_enricher.py` がメインページから物件写真（`suumo_images`、サムネイル用）、間取りタブ（`{url}madori/`）から検索条件合致の間取り図（`floor_plan_images`）を取得 |
| 間取りフィルタ | 間取りタブの全タイプから `LAYOUT_PREFIX_OK`（= "2", "3"）に合致するもののみ採用 |
| 出力 | `SuumoShinchikuListing` dataclass |

#### 5.3.4 ~~HOME'S 新築（homes_shinchiku_scraper.py）~~ — 現在無効

> 中古と同様の理由で無効化。権利形態（ownership）取得ロジックは実装済み（テーブルの「権利形態」「敷地の権利形態」「権利」ラベル + `parse_ownership` / `parse_ownership_from_text` フォールバック）。

### 5.4 物件名クリーニング（`clean_listing_name`）

`report_utils.py` の `clean_listing_name()` が各スクレイパー内部および `main.py` の後処理で適用され、物件名のノイズを除去する。

| 処理 | 例 |
|------|---|
| プレフィックス除去 | 「新築マンション」「マンション未入居」「マンション」を先頭から除去 |
| サフィックス除去 | 末尾の「閲覧済」を除去 |
| 販売期情報除去 | 「第1期1次」「( 第2期 2次 )」を末尾から除去 |
| キャッチコピー抽出 | 「眺望良好「XXX」」→「XXX」（括弧外が路線名・駅名でない場合） |
| 非物件名テキスト除外 | 「掲載物件X件」→ 空 |
| 条件タグ除外 | 「ペット可」「リフォーム済」「角部屋」等の物件特徴タグ → 空 |
| 路線情報のみ除外 | 「○○線○○駅徒歩X分」のみのテキスト → 空 |

条件タグ除外（`_is_feature_tag`）は、CSS クラス `title` / `name` にマッチするバッジ要素や h2-h4 見出しから物件条件テキスト（「ペット可」「即入居可」「リノベーション済」等）が物件名として誤抽出されるのを防ぐ。完全一致リスト（`_NOT_A_NAME_EXACT`）とパターンマッチ（`_NOT_A_NAME_PATTERNS`）の2段階で判定。クリーニング後に条件タグだけが残った場合も再判定して空を返す。

`main.py` の後処理では `clean_listing_name` が空を返した場合に「（不明）」をフォールバック値として設定する。

### 5.5 フィルタ・重複除去

#### フィルタ条件（`apply_conditions`）

各スクレイパーの結果に、次の条件でローカルフィルタ（`apply_conditions`）をかける。

> サーバーサイドフィルタとして、SUUMO 中古では JJ012FC001 エンドポイントの `kb`/`kt`（価格）、`mb`（面積下限）、`et`（駅徒歩上限）パラメータでサーバー側の絞り込みを行う。`mb`/`et` は SUUMO が受け付ける固定値のみ使用可（mb: 20,30,40,50,60,70,80,90,100、et: 1,3,5,7,10,15,20）。config 値は `_snap_mb`（切り捨て）・`_snap_et`（切り上げ）で最寄り固定値に丸める。ローカルフィルタはこの結果に対してさらに正確な面積・間取り・築年・徒歩等の条件で絞り込む2段構成

- 東京23区以内
- 価格: `PRICE_MIN_MAN`〜`PRICE_MAX_MAN`
- 面積: `AREA_MIN_M2` 以上
- 間取り: `LAYOUT_PREFIX_OK` に前方一致
- 築年: `BUILT_YEAR_MIN` 以降
- 徒歩: `WALK_MIN_MAX` 以内
- 総戸数: `TOTAL_UNITS_MIN` 以上
- 駅名: `ALLOWED_STATIONS` のいずれかを `station_line` に含む（空の場合は駅名フィルタなし）
- 路線: `ALLOWED_LINE_KEYWORDS` のいずれかを含む（空の場合は路線フィルタなし。`ALLOWED_STATIONS` と併用時はいずれかを満たせば通過）
- 駅乗降客数: `STATION_PASSENGERS_MIN` 以上（0 = フィルタなし）

#### 重複除去（`dedupe_listings`）

`listing_key` = (normalize_listing_name(name), layout, area, price, normalized_address, built_year, station_name) の組み合わせで一意化する。重複件数は `duplicate_count` に記録する。`station_line` の路線テキストはＪＲ総武線とＪＲ総武線快速のように表記が揺れるため、キーには駅名だけを使う。`walk_min` はキーから除外する。address は `_normalize_address_for_key` で丁目レベルに正規化（番地以下の精度差を吸収）。`normalize_listing_name` は◆装飾・【】・階数・PROJECT等の説明文を除去し、空白除去・中黒（・）除去・既知の誤字補正を行う強化版正規化を適用。◆NAME◆ パターン（先頭◆で囲まれた物件名）は内容を抽出して空文字化を防止。

### 5.6 エンリッチャー

#### 5.6.1 ハザードエンリッチャー（hazard_enricher.py）

国土地理院タイルと東京都地域危険度のGeoJSONから、次を付与する。

- GSIタイルは `ThreadPoolExecutor`（max_workers=5）で、同一物件の複数タイル種別を並列取得する。タイルキャッシュは `Lock` でスレッドセーフにしている。リクエスト間隔は0.05秒
- 洪水浸水深、内水浸水深、土砂災害警戒、高潮浸水深、津波浸水深
- 液状化（地形分類）。治水地形分類図 `lcmfc2` で代替
- 建物倒壊危険度、火災危険度、総合危険度

#### 5.6.2 住まいサーフィンエンリッチャー（sumai_surfin_enricher.py）

| 項目 | 詳細 |
|------|------|
| 認証 | `SUMAI_USER` / `SUMAI_PASS` 環境変数 |
| 並列処理 | `ThreadPoolExecutor`（max_workers=3）で HTTP 検索・パースを並列実行する。未 enrichment 物件だけを事前に絞り込み、並列ループに投入する。各ワーカーは独自セッションでログインし、`DELAY`（1.5秒以上）でレート制限を維持する。listings は in-place 更新であり、スレッドごとに異なる dict を扱うため競合しない |
| インクリメンタル処理 | `--previous` で前回結果 JSON を指定すると、URL でマッチし価格・物件名が同一かつ `ss_lookup_status` がある物件は SS フィールドをコピーしてスキップ。新規・変更・未 enrichment 物件のみ実際に検索・パースする。ログに「スキップ: N件, enrichment対象: M件」を出力 |
| ブラウザ自動操作 | Playwright（`sumai_surfin_browser.py`） |
| 取得データ | 沖式時価、儲かる確率、値上がり率、レーダーチャート、割安判定、ランキング等 |

沖式中古時価70㎡換算のデータソースは、次の優先順位で使う。

| 優先度 | ソース | 説明 |
|--------|--------|------|
| 1（最優先） | 検索結果一覧ページのカード | `_extract_search_result_inline()` で物件カードから直接抽出。ヘルプ文の誤マッチリスクがなく最も信頼性が高い |
| 2（フォールバック） | 物件詳細ページ | `_extract_oki_price_chuko()` で HTML 正規表現抽出。ページ下部のヘルプ文「例：X,XXX万円」の例示値を誤取得しないよう、マッチ直前の「例：」パターンを除外する |

#### 5.6.3 不動産情報ライブラリエンリッチャー（reinfolib_enricher.py）

| 項目 | 詳細 |
|------|------|
| データソース | `data/reinfolib_prices.json`, `data/reinfolib_trends.json`, `data/reinfolib_raw_transactions.json`（事前構築キャッシュ） |
| 付与データ | 区・駅レベルの成約 m² 単価、相場乖離率、前年比、四半期推移（区: 過去5年分）、同一マンション成約事例（信頼度スコア付き） |
| キャッシュ構築 | `reinfolib_cache_builder.py`（`YEARS_BACK=5` で過去5年分の四半期推移を取得、`RAW_TX_QUARTERS=8` で直近8四半期の生取引データを保存）/ `fetch_station_prices.py`（別ワークフローで実行） |
| 区名抽出 | `parse_utils.extract_ward` に委譲する |
| 同一マンション推定 | 同区 + 同町名 + 築年±1年 + 同構造 + 延床面積±20%（あれば）でマッチング。信頼度を high / medium / low で付与する。`TotalFloorArea`・`CoverageRatio`・`FloorAreaRatio` を API レスポンスから保存し、照合に使う |

#### 5.6.4 e-Stat 人口動態エンリッチャー（estat_enricher.py）

| 項目 | 詳細 |
|------|------|
| データソース | `data/estat_population.json` + `data/estat_aging.json`（事前構築キャッシュ） |
| 付与データ | 区の人口、世帯数、前年比、5年変動、年次推移、高齢化率（当該区・全国平均・23区平均の推移） |
| キャッシュ構築 | `estat_population_builder.py`（人口・世帯数）、`estat_aging_builder.py`（高齢化率）を別ワークフローで実行する |
| 高齢化率データ | 国勢調査（2000, 2005, 2010, 2015, 2020）の年齢3区分データから65歳以上人口割合を取得。全国・23区平均・区別の3系列 |
| 区名抽出 | `parse_utils.extract_ward` に委譲する |

#### 5.6.5 マンションレビューエンリッチャー（mansion_review_scraper.py）

| 項目 | 詳細 |
|------|------|
| データソース | mansion-review.jp（HTTP スクレイピング） |
| 付与データ | マンション偏差値、推定適正価格（万円）、推定坪単価、推定m²単価、騰落率、中古販売履歴件数、公開販売履歴テーブル |
| キャッシュ | `data/mansion_review_cache.json`（物件名正規化 → 建物データ。TTL: 14日） |
| 実装方式 | HTTP（requests + BeautifulSoup）。リクエスト間隔は3秒 |
| 対象 | 中古のみ（新築はスキップ） |
| パイプライン統合 | `run_enrich.sh` の `mansion` トラックで実行する（Track G は現在、HOME'S 画像のトラックである）。`merge_enrichments.py` で `mansion_review_data` フィールドをマージする |

#### 5.6.6 間取り図・物件写真エンリッチャー

##### 中古（build_units_cache.py → merge_detail_cache.py / floor_plan_enricher.py）

| 項目 | 詳細 |
|------|------|
| データソース | SUUMO: `build_units_cache.py` → `parse_suumo_detail_html()` で詳細ページ HTML から画像・属性を抽出。`alt="間取り図"` → `floor_plan_images`、それ以外の物件画像（外観・リビング・キッチン・浴室等）→ `suumo_images`。`_detail_to_cache_entry` が direction, balcony_area_m2, parking, constructor, zoning, repair_fund_onetime, delivery_date, feature_tags を `building_units.json` に格納（HOME'S は無効化のため現在未使用） |
| 並列取得 | `ThreadPoolExecutor(max_workers=4)` で SUUMO 詳細ページの HTTP 取得を並列化する |
| HTML ハッシュキャッシュ | `parse_hashes.json` で HTML コンテンツのハッシュを保持する。変更がなければ再パースをスキップする |
| ETag 条件付きリクエスト | `data/html_cache/etags.json` で URL ごとに ETag・Last-Modified・cached_at を保持する。`STALE_DAYS`（0日。掲載終了を即日検知するため、キャッシュ済み HTML も毎回再検証する）を超えて経過したキャッシュは `If-None-Match` / `If-Modified-Since` ヘッダー付きで再検証する。304 Not Modified なら cached_at だけ更新して帯域を節約し、200 なら HTML キャッシュを更新して再パースする |
| 付与データ（間取り図） | `floor_plan_images` は間取り図画像 URL の配列（SUUMO はリサイズ URL w=1200&h=900） |
| 付与データ（物件写真） | `suumo_images` は `[{url, label}]` 形式の物件写真配列。label は SUUMO の alt 属性（"現地外観写真", "リビング", "キッチン" 等）。サイトロゴ・担当者写真・spacer 等の非物件画像は除外する |
| 付与データ（追加属性） | `direction`, `balcony_area_m2`, `parking`, `constructor`, `zoning`, `repair_fund_onetime`, `delivery_date`（中古の引渡可能時期）, `feature_tags`。`merge_detail_cache.py` の KEYS と `merge_enrichments.py` の ENRICHER_FIELDS["units_cache"] に含まれる |
| HTMLキャッシュ | `data/html_cache/`（build_units_cache.py と共有） |

##### 新築（shinchiku_detail_enricher.py）

| 項目 | 詳細 |
|------|------|
| データソース | SUUMO 新築マンション詳細ページ（メインページ + 間取りタブ `{url}madori/`）から画像を取得 |
| 物件写真（サムネイル用） | メインページから外観/完成予想図/モデルルーム等の写真を `suumo_images` として取得する。一覧画面で中古と同様にサムネイル表示される |
| 間取り図（条件フィルタ付き） | 間取りタブから各住戸タイプの間取り図を取得し、`LAYOUT_PREFIX_OK`（= "2", "3"）に合致するタイプだけを `floor_plan_images` に格納する。例: 1LDK〜4LDK の全5タイプ中、2LDK・3LDK の2タイプだけを採用 |
| レイアウト抽出 | 画像の `alt` 属性と親要素のテキストから間取りパターン（例: "3LDK"）を抽出し、`LAYOUT_PREFIX_OK` でフィルタする |
| HTMLキャッシュ | `data/shinchiku_html_cache/`（独立キャッシュ。再取得で復元できるため Git 管理外） |
| ETag 条件付きリクエスト | `data/shinchiku_html_cache/etags.json` で URL ごとに ETag・Last-Modified・cached_at を保持する。未キャッシュ URL の新規取得時に、レスポンスヘッダーから保存する |

##### 共通（upload_floor_plans.py）

| 項目 | 詳細 |
|------|------|
| Firebase Storage 永続化 | `upload_floor_plans.py` が間取り図を `floor_plans/{hash}.{ext}`、物件写真を `property_images/{hash}.{ext}` にアップロードし、URL をトークン付きダウンロード URL に置き換える。マニフェスト（`data/floor_plan_storage_manifest.json`）に元 URL と Firebase URL の対応を保持し、重複アップロードを避ける。`ThreadPoolExecutor`（8並列）でダウンロードとアップロードを並行処理する。`--max-time` オプションで最大実行時間を指定でき、超過時は未処理分をスキップする。finalize ジョブ内で実行するため、enrich ジョブのタイムアウトに影響しない。`FIREBASE_SERVICE_ACCOUNT` 未設定時はスキップする |
| iOS 側フィールド（間取り図） | `Listing.floorPlanImagesJSON`（JSON 文字列。`parsedFloorPlanImages: [URL]` で URL 配列に変換する。`ListingJSONCache` でキャッシュし、body 再評価時の冗長なデコードを避ける） |
| iOS 側フィールド（物件写真） | `Listing.suumoImagesJSON`（JSON 文字列。`parsedSuumoImages: [SuumoImage]` で構造体配列に変換し、`ListingJSONCache` でキャッシュする。`SuumoImage` は `url`/`label` を持ち、`category` で外観/室内/水回り/その他に自動分類する） |
| サムネイル URL | `Listing.thumbnailURL: URL?`（computed）。SUUMO 物件写真から外観カテゴリ（`category == .exterior`）の画像を優先的に選択し、外観写真がない場合は先頭画像にフォールバック。一覧カードでは `TrimmedAsyncImage` で白余白を自動トリミング・幅 100pt × 高さ 75pt の固定サイズで `.fill` + クリップ表示。画像キャッシュは 2 層: メモリ（`TrimmedImageCache` / NSCache）→ ディスク（`DiskImageCache` / Caches/ImageCache）→ ネットワーク取得。取得後にメモリ・ディスク両方へ保存 |

### 5.7 成約実績フィード構築（build_transaction_feed.py）

東京23区の成約実績データを取得・フィルタ・ジオコード・集約して iOS アプリ向け `transactions.json` を生成するバッチスクリプト。スクレイピングツール（suumo_scraper.py）と同じ購入条件に合致する成約物件だけを対象とする。

| 項目 | 詳細 |
|------|------|
| 入力 | reinfolib API（成約価格情報 `priceClassification=02`）、`data/shutoken_city_codes.json`（東京23区のみ使用）、`data/geocode_cache.json`、`data/station_cache.json` |
| 出力 | `results/transactions.json` |
| 対象地域 | 東京23区のみ（`config.py` の `TOKYO_23_WARDS` で定義。`shutoken_city_codes.json` から東京都 pref_code=13 の23区コードだけをロードする） |
| フィルタ条件 | `config.py` の購入条件（価格帯・面積・間取り・築年 + 駅徒歩）を適用する。スクレイピングと同一条件 |
| 駅徒歩フィルタ | ジオコーディングと最寄駅推定の後に、`estimated_walk_min <= WALK_MIN_MAX`（`ScrapingConfigMetadata.json` の既定は10分以内）でフィルタする。座標が取得できず徒歩を推定できなかったレコードも除外する |
| ジオコーディング | 町丁目アドレス → 緯度経度（geocode_cache.json 優先、不足分は Nominatim API） |
| 最寄駅推定 | ジオコーディング座標 + station_cache.json → Haversine 距離で最近傍駅を算出し、直線距離 80m/分で徒歩時間を推定する |
| 建物グルーピング | `districtCode-builtYear-structure-totalFloorAreaBucket` の組で推定建物グループを構成する（延床面積は1000m²単位のバケット。構造・延床面積がない場合は省略）。グループ別に取引件数、価格帯、平均 m² 単価を集計する |
| 物件名推定 | `latest.json` / `latest_shinchiku.json` の既存スクレイピングデータと突き合わせる。市区町村+町丁目+築年（±1年）が一致した物件名を `estimated_building_name` として付与する。複数候補は " / " 区切り |
| 取得期間 | 直近20四半期（約5年分）。成約価格情報は四半期終了後 約3ヶ月遅れで公開されるため、直近1四半期はデータなしになることが多い |
| 実行間隔 | WF2 の `build-transaction-feed` ジョブで毎回実行する（`REINFOLIB_API_KEY` 設定時のみ）。ローカルでは `update_listings.sh` から呼び出す |
| CLI オプション | `--quarters N`（取得四半期数、デフォルト20）、`--output PATH`（出力先） |

#### transactions.json 構造

```json
{
  "transactions": [
    {
      "id": "tx-xxxxxxxxx",
      "prefecture": "東京都",
      "ward": "江東区",
      "district": "有明",
      "district_code": "131080020",
      "price_man": 7800,
      "area_m2": 70.0,
      "m2_price": 1114286,
      "layout": "3LDK",
      "built_year": 2019,
      "structure": "RC",
      "trade_period": "2025Q2",
      "nearest_station": "有明テニスの森",
      "estimated_walk_min": 5,
      "latitude": 35.6358,
      "longitude": 139.7908,
      "building_group_id": "131080020-2019",
      "estimated_building_name": "シティタワー有明"
    }
  ],
  "building_groups": [
    {
      "group_id": "131080020-2019",
      "ward": "江東区",
      "district": "有明",
      "built_year": 2019,
      "transaction_count": 5,
      "price_range_man": [6500, 9800],
      "avg_m2_price": 1050000,
      "estimated_building_name": "シティタワー有明"
    }
  ],
  "metadata": { ... }
}
```

### 5.8 通勤時間ツール

| ファイル | 用途 | ステータス |
|---------|------|---------|
| commute.py | コアロジック。駅名パース、通勤時間計算、表示文字列生成 | パイプラインで使用 |
| commute_enricher.py | 駅名ベースのドアtoドア概算を `commute_info` として JSON に付与する。`--force` で既存データを再計算して上書きする | パイプラインで使用（Track C） |
| commute_gmaps_enricher.py | Playwright で Google Maps をスクレイピングし、物件住所から各オフィスへの door-to-door 通勤時間を取得する。`source: "gmaps"` フラグ付き。到着 9:00 JST | パイプラインで使用（Track F） |
| commute_audit.py | 手動監査用 HTML 生成（Google Maps との比較） | 監査用 |
| commute_auto_audit.py | Playwright 自動監査。Google Maps に到着 8:30 で経路検索し、所要時間を抽出する | 監査用 |
| data/commute_playground.json | 駅名 → Playground までの電車時間（分）のルックアップテーブル。`.gitignore` の対象でリポジトリに含まれない | `commute_auto_audit.py` で更新 |
| data/commute_m3career.json | 駅名 → M3Career までの電車時間（分）のルックアップテーブル。`.gitignore` の対象でリポジトリに含まれない | `commute_auto_audit.py` で更新 |

#### 5.8.1 通勤エンリッチャー（commute_enricher.py）オプション

| オプション | 説明 |
|-----------|------|
| `--force` | 既存の `commute_info` があってもスキップせず、再計算して上書きする。指定しない場合は既存データがある物件をスキップする（デフォルト動作）。`enrich_commute()` の `force: bool = False` パラメータに対応する |

#### 5.8.2 Google Maps 通勤エンリッチャー（commute_gmaps_enricher.py）

物件住所をGoogle Mapsの出発地に入力し、公共交通機関経路の所要時間をPlaywrightでスクレイピングして取得する。`commute_enricher.py`（駅テーブルベース）より精度が高い実測値を取得する。

| オプション | 説明 |
|-----------|------|
| `--input` / `--output` | 入出力 JSON ファイル |
| `--workers N` | 並列ワーカー数（デフォルト: 2） |
| `--force` | 全物件を再取得（`source: "gmaps"` 既存データも上書き） |
| `--no-headless` | ブラウザを表示して実行（デバッグ用） |
| `--reset` | レジューム用キャッシュ（`commute_gmaps_cache/`）をリセット |

キャッシュ（`commute_gmaps_cache/results.json`）は CI 間で `actions/cache/restore` / `actions/cache/save`（`if: always()`）により永続化される。タイムアウトでジョブがキャンセルされても部分キャッシュが保存され、次回実行時に未取得分のみスクレイピングする。`commute_gmaps_cache/` は `.gitignore` の対象で、リポジトリにコミットしない。

マージ順序: Track C（commute_enricher）→ Track F（commute_gmaps_enricher）で、Track F の結果が優先される。

### 5.9 分析・予測

| ファイル | 機能 |
|---------|------|
| parse_utils.py | 共通パーサー。`parse_monthly_yen`（管理費・修繕積立金等。「18,000」「18000」のような円マークなし・カンマ区切り・純粋数値にも対応）、`extract_ward`（住所から区名を取り出す。reinfolib_enricher と estat_enricher が委譲する） |
| mansion_review_scraper.py | マンションレビューのスクレイパー。物件名から建物ページを検索し、偏差値・推定価格・騰落率・販売履歴をパースする。HTTP ベース（requests + BeautifulSoup）。TTL 14日のキャッシュ |
| shared_utils.py | 共通ユーティリティ（`ward_from_address`, `calc_loan_residual_10y_yen`、ローン定数） |
| price_predictor.py | `MansionPricePredictor`。CSV データに基づく価格予測 |
| asset_score.py | 資産ランク S/A/B/C の算出（含み益率ベース） |
| investment_enricher.py | 投資スコア・掲載日数・競合物件数・価格履歴を付与する。asset_score を利用する |
| asset_simulation.py | 10年シミュレーション。`simulate_10year_from_listing(listing, predictor=...)` で Predictor を再利用できる。`simulate_batch(listings)` で複数物件を一括処理する（CSV 読込は1回） |
| future_estate_predictor.py | 10年価格予測（3シナリオ） |
| loan_calc.py | 50年ローン月額返済額計算 |
| scripts/validate_data.py | 物件データのバリデーション。ValidationResult、validate_listings（必須フィールド・異常値・重複URL検出） |
| scripts/build_supply_trends.py | 供給トレンド集計。区別・四半期別の物件件数を aggregate_trends で集計する |

`price_predictor` と `future_estate_predictor` は `shared_utils` を利用する。CSV/JSONの読込は try/except で囲み、ファイルが欠けている場合は警告を出し、空のDataFrameとデフォルト値で続行する。

### 5.10 レポート生成

`generate_report.py` が次のレポートをMarkdownで生成する。`report_utils.row_merge_key` は物件名・価格・間取りに加えて住所（address）と築年（built_year）をキーに含め、異なる建物の物件が誤ってマージされるのを防ぐ。

| セクション | 内容 |
|-----------|------|
| 新着物件 | 前回から追加された物件 |
| 価格変更 | 前回から価格が変わった物件。物件名の後ろに価格変動日を「（M/D）」形式で表示する（`price_history` の直近エントリの日付） |
| 掲載終了 | 前回から消えた物件 |
| 区別一覧 | 区ごとの物件リスト |
| 駅別一覧 | 駅ごとの物件リスト |
| オプション | 資産ランク、通勤時間、ローン情報（有効な場合） |

### 5.11 出力ファイル

| ファイル | 形式 | 内容 |
|---------|------|------|
| `results/latest.json` | JSON | 中古マンション物件リスト |
| `results/latest_shinchiku.json` | JSON | 新築マンション物件リスト |
| `results/report/report.md` | Markdown | 差分レポート |
| `results/map_viewer.html` | HTML | 地図ビューア（中古+新築。ピン色: 青=中古、緑=新築） |
| `data/commute_playground.json` | JSON | Playground 通勤時間マスター（`.gitignore` の対象） |
| `data/commute_m3career.json` | JSON | M3Career 通勤時間マスター（`.gitignore` の対象） |
| `data/geocode_cache.json` | JSON | ジオコーディングキャッシュ |
| `data/parse_hashes.json` | JSON | build_units_cache 用 HTML キャッシュハッシュ（変更なし時は再パーススキップ） |
| `data/building_units.json` | JSON | 総戸数・階数・権利形態・向き・バルコニー面積・駐車場・施工会社・用途地域・修繕積立基金・引渡時期・特徴タグのキャッシュ |
| `data/reinfolib_prices.json` | JSON | 不動産情報ライブラリ区別成約相場キャッシュ |
| `data/reinfolib_trends.json` | JSON | 不動産情報ライブラリ四半期推移キャッシュ（過去5年分） |
| `data/reinfolib_raw_transactions.json` | JSON | 不動産情報ライブラリ生取引データ（直近8四半期分。`TotalFloorArea`・`CoverageRatio`・`FloorAreaRatio` を含む） |
| `data/station_price_history.json` | JSON | 駅別成約価格推移キャッシュ |
| `data/estat_population.json` | JSON | e-Stat 区別人口・世帯数キャッシュ |
| `data/sumai_surfin_cache.json` | JSON | 住まいサーフィン検索結果キャッシュ |
| `data/mansion_review_cache.json` | JSON | マンションレビュー建物データキャッシュ（物件名正規化→{data, cached_at}。TTL: 14日） |
| `data/station_passengers.json` | JSON | 駅乗降客数データ |
| `data/shutoken_city_codes.json` | JSON | 首都圏（1都3県）市区町村コード一覧 |
| `data/html_cache/etags.json` | JSON | 中古詳細ページの ETag・Last-Modified・cached_at キャッシュ（Phase3） |
| `data/shinchiku_html_cache/etags.json` | JSON | 新築詳細ページの ETag・Last-Modified・cached_at キャッシュ（Phase3） |
| `results/transactions.json` | JSON | 東京23区成約実績フィード（iOS アプリ向け、スクレイピングと同一検索条件） |
| `scripts/validate_data.py` | Python | データ品質バリデーション（Phase3） |
| `scripts/cache_manager.py` | Python | TTL ベースキャッシュクリーンアップ（Phase3） |

### 5.12 テスト（scraping-tool/tests/）

pytest によるユニットテスト。`pytest tests/ -v` で実行する。次の表は主なテストファイルを示す。全体は `scraping-tool/tests/` を参照する。

| テストファイル | 対象 |
|---------------|------|
| test_report_utils.py | `report_utils` の identity_key、listing_key、compare_listings、フォーマット関数 |
| test_suumo_scraper.py | `suumo_scraper.parse_suumo_detail_html` の詳細ページパース |
| test_investment_enricher.py | `investment_enricher` の投資スコア、掲載日数、競合物件数、価格履歴注入 |
| test_validate_data.py | `scripts/validate_data` の ValidationResult、validate_listings（空リスト・必須フィールド・異常値・重複URL） |
| test_build_supply_trends.py | `scripts/build_supply_trends` の aggregate_trends、空入力時の挙動 |

---

## 6. データモデル

### 6.1 Listing（SwiftData @Model）

iOSアプリのメインデータモデル。`SupabaseListingStore` がSupabaseから物件を取得して同期する。1件は、パイプラインが出力する `scraping-tool/results/latest.json` の1件と同じ項目を持つ。新築物件の取得と表示は2026-06-03に廃止した（コミット `dd1bdb45`）。`propertyType` などの新築用フィールドはモデルに残っている。

#### 基本情報

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `source` | String? | データソース（"suumo", "homes"） |
| `url` | String | 物件詳細ページ URL |
| `name` | String | 物件名 |
| `priceMan` | Int? | 価格（万円） |
| `address` | String? | 住所 |
| `ssAddress` | String? | 住まいサーフィンから取得した番地レベルの詳細住所（パイプライン側で付与。ジオコーディング精度向上に使用） |
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
| `managementFee` | Int? | 管理費（円/月。SUUMO/HOME'S 詳細ページから取得） |
| `repairReserveFund` | Int? | 修繕積立金（円/月。SUUMO/HOME'S 詳細ページから取得） |
| `direction` | String? | 向き（方角。例: "南", "北西"。SUUMO 詳細ページから取得） |
| `balconyAreaM2` | Double? | バルコニー面積（㎡） |
| `parking` | String? | 駐車場（例: "空有 月額20,000円〜25,000円"） |
| `constructor` | String? | 施工会社（例: "大林組"） |
| `zoning` | String? | 用途地域（例: "商業地域"） |
| `repairFundOnetime` | Int? | 修繕積立基金（円。一時金。SUUMO 詳細ページから取得） |
| `featureTagsJSON` | String? | 特徴タグ JSON（例: `["駅徒歩5分以内","2沿線以上利用可"]`。SUUMO の gapSuumoPcForKr から取得） |
| `listWardRoman` | String? | 区（ローマ字） |
| `fetchedAt` | Date | 取得日時 |
| `addedAt` | Date | 初回追加日時（同期で上書きしない。新規挿入時は `firstSeenAt`（サーバーサイドの初回検出日）があればそれを使用し、なければ `fetchedAt` にフォールバック。スキーマリセット後も正しい追加日順ソートを維持する） |

#### ユーザーデータ

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `memo` | String? | メモ（レガシー、コメントに移行済み） |
| `isLiked` | Bool | いいね状態 |
| `commentsJSON` | String? | コメント JSON（Supabaseの `user_annotations` と同期） |
| `isDelisted` | Bool | 掲載終了フラグ |
| `isNew` | Bool | サーバーサイドで判定された新着フラグ（JSON の `is_new` から取得。同期ごとにリセット。304 応答時も確実にリセット） |
| `isNewBuilding` | Bool | 新着かつ同一マンション名が前回データに存在しない＝新規マンション（false＝既存マンションの別部屋。JSON の `is_new_building` から取得。同期ごとにリセット） |
| `viewedAt` | Date? | 最終閲覧日時（物件詳細画面を開いた日時。最近見た物件一覧用） |
| `checklistJSON` | String? | 内見チェックリスト JSON 文字列（ローカル保存。ChecklistItem 配列のエンコード） |
| `photosJSON` | String? | 内見写真メタデータ JSON |
| `floorPlanImagesJSON` | String? | 間取り図画像 URL の JSON 文字列。`["url1", "url2"]` 形式。画像ストレージ（R2。未設定ならSupabase Storage）上のURL |
| `suumoImagesJSON` | String? | SUUMO 物件写真の JSON 文字列。`[{"url":"...","label":"リビング"}, ...]` 形式。カテゴリ別（外観/室内/水回り/その他）にグルーピングして表示 |

#### 新築固有フィールド

新築の取得は廃止済みで、既定値は `propertyType = "chuko"` です。次のフィールドはモデルに残っています。

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `propertyType` | String | "chuko" or "shinchiku" |
| `priceMaxMan` | Int? | 価格帯上限（万円） |
| `areaMaxM2` | Double? | 面積幅上限（㎡） |
| `deliveryDate` | String? | 引渡時期。新築は一覧から取得、中古は詳細ページの「引渡可能時期」から取得（例: "即引渡可"） |

#### 位置情報

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `latitude` | Double? | 緯度 |
| `longitude` | Double? | 経度 |
| `duplicateCount` | Int | 重複集約数 |

#### マンション単位グルーピング（computed property）

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `buildingGroupKey` | String (computed) | 同一マンション判定用キー。`cleanListingName(name)`（空白除去 + 中黒除去 + 誤字補正） + `extractWardFromAddress(address)`（区名のみ）を `\|` 区切りで結合。住所は区名のみ使用し、番地の有無や住所誤入力を吸収。floorTotal・ownership・walkMin・totalUnits・builtYear はSUUMOデータの欠損や不整合が多いためキーから除外。同一敷地内の別棟は棟名（コート名、タワー名等）で区別される。一覧画面のランタイムグルーピングに使用。`@Transient` でキャッシュし、グルーピング時の regex 再計算を回避 |

#### 住まいサーフィン評価データ

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `ssLookupStatus` | String? | 住まいサーフィン検索ステータス（"found" / "not_found" / "no_data" / nil=未検索） |
| `ssProfitPct` | Int? | 沖式儲かる確率 (%) |
| `ssOkiPrice70m2` | Int? | 沖式中古時価（万円, 70㎡換算） |
| `ssM2Discount` | Int? | m²割安額（万円/㎡）、負値=割安 |
| `ssValueJudgment` | String? | 割安判定（"割安"/"適正"/"割高"） |
| `ssStationRank` | String? | 駅ランキング |
| `ssWardRank` | String? | 区ランキング |
| `ssSumaiSurfinURL` | String? | 住まいサーフィンページ URL |
| `ssAppreciationRate` | Double? | 中古値上がり率 (%)。取得にはログインが必須（必ずログイン後に取得する）。SS データが存在するが未取得の場合は UI で「—」を表示 |
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
| `commuteInfoJSON` | String? | 通勤時間情報 JSON（パイプラインの `commute_info` から初期値を取り込み、MKDirections で上書き可能） |
| `reinfolibMarketData` | String? | 不動産情報ライブラリの成約価格相場データ JSON（パイプライン側で付与）。同一マンション成約事例に `confidence`（high/medium/low）フィールドを含む |
| `mansionReviewData` | String? | マンションレビュー（mansion-review.jp）の建物データ JSON（パイプライン側で付与）。偏差値・推定適正価格・騰落率・販売履歴件数を含む |
| `estatPopulationData` | String? | e-Stat（総務省統計局）の人口・世帯数・高齢化率データ JSON（パイプライン側で付与）。高齢化率は国勢調査5年ごとの全国平均・23区平均・当該区の3系列推移を含む |

#### 投資判断支援データ（Phase1 追加）

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `priceHistoryJSON` | String? | 価格変動履歴 JSON。`[{"date":"2025-02-20","price_man":9500},...]` 形式。パイプラインで前回比較時に自動蓄積 |
| `firstSeenAt` | String? | 初回掲載検出日（ISO8601 日付）。パイプラインで初出時に日付を記録し、以降は継承 |
| `priceFairnessScore` | Int? | 掲載価格の妥当性スコア（0-100）。住まいサーフィン評価・reinfolib 相場との比較で算出。50=適正、50超=割安 |
| `resaleLiquidityScore` | Int? | 再販流動性スコア（0-100）。駅距離・総戸数・エリア需要・面積帯から算出 |
| `competingListingsCount` | Int? | 同一マンション内の競合売出物件数。同じ正規化物件名+区名の物件をカウント |
| `listingScore` | Int? | 総合投資スコア（0-100）。価格妥当性・流動性・騰落率・儲かる確率・ハザード・通勤時間・人口動態の重み付き平均 |

#### Computed Properties（投資判断）

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `parsedPriceHistory` | [PriceHistoryEntry] | パース済み価格変動履歴 |
| `hasPriceChanges` | Bool | 2件以上の価格エントリがあるか |
| `latestPriceChange` | Int? | 直近の価格変動額（万円、正=値上げ、負=値下げ） |
| `daysOnMarket` | Int? | 掲載日数（`firstSeenAt` から計算） |
| `daysOnMarketDisplay` | String | 掲載日数の表示用文字列（例: "15日間掲載"、"本日掲載"） |
| `listingScoreGrade` | String | スコアグレード（"excellent"/"good"/"average"/"belowAverage"/"poor"） |
| `scoreBreakdown` | [ScoreComponent] | 総合スコアの構成要素一覧。各要素は label/icon/score/weight/detail を持つ。Python の `_calc_listing_score` と同じ7指標（価格妥当性・再販流動性・値上がり率・儲かる確率・ハザード・通勤利便性・人口動態）を iOS 側で再現。データがある指標のみ含む |
| `wardName` | String | 住所から抽出した区名（例: "世田谷区"） |

### 6.2 TransactionRecord（SwiftData @Model）

iOSアプリの成約実績データモデル。`scraping-tool/results/transactions.json` の1取引に対応する。
reinfolib API（不動産情報ライブラリ）の成約価格情報から、`config.py` の購入条件（価格帯、面積、間取り、築年、駅徒歩）に合う東京23区のレコードを抽出する。条件の値はスクレイピングと同じで、[9.1](#91-スクレイピング検索条件configpy) の表に従う。

#### 取引情報

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `txId` | String | ユニーク ID（`@Attribute(.unique)`、"tx-" + MD5ハッシュ12桁） |
| `prefecture` | String | 都道府県（例: "東京都"） |
| `ward` | String | 市区町村（例: "江東区"） |
| `district` | String | 町丁目（例: "有明"） |
| `districtCode` | String | 町丁目コード（例: "131080020"） |
| `priceMan` | Int | 成約価格（万円） |
| `areaM2` | Double | 専有面積（㎡） |
| `m2Price` | Int | m²単価（円/㎡） |
| `layout` | String | 間取り（例: "3LDK"） |
| `builtYear` | Int | 築年（例: 2019） |
| `structure` | String | 構造（例: "RC", "SRC"） |
| `tradePeriod` | String | 取引時期（例: "2025Q2"） |

#### 推定位置情報

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `nearestStation` | String? | 推定最寄駅名（geocode + station_cache.json から算出） |
| `estimatedWalkMin` | Int? | 推定徒歩分（直線距離ベース、精度 ±2-3分） |
| `latitude` | Double? | ジオコーディング済み緯度（町丁目レベル） |
| `longitude` | Double? | ジオコーディング済み経度（町丁目レベル） |

#### グルーピング・推定物件名

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `buildingGroupId` | String? | 推定建物グループ ID（"districtCode-builtYear"） |
| `estimatedBuildingName` | String? | スクレイピングデータとのクロスリファレンスで推定した物件名。複数候補は " / " 区切り |

#### 物件名推定ロジック

`build_transaction_feed.py` は、`latest.json` と `latest_shinchiku.json` のスクレイピング済み物件データを参照元にする（`latest_shinchiku.json` は存在すれば読む）。
マッチ条件は、市区町村名、町丁目名、築年（±1年）の一致である。一致した物件の名前を候補として付ける。
複数候補があれば最大3件を " / " 区切りで連結する。
マッチしない場合は `null` になり、iOSアプリは「{市区町村}{町丁目} {築年}年築」を代わりに表示する。

#### データソース・制約

- 匿名データで、建物名は含まれない。町丁目と築年で建物を推定してグルーピングする。物件名は既存のスクレイピングデータから推定する
- 最寄駅は推定値である。reinfolib APIの成約データには駅情報がないため、ジオコーディング座標から最近傍駅を算出する
- 対象範囲は東京23区のみ。`build_transaction_feed.py` が `shutoken_city_codes.json` から東京都（都道府県コード13）の23区だけを読み込む。`results/transactions.json` の全9,349件が東京都である
- `config.py` の購入条件でフィルタ済み。値は [9.1](#91-スクレイピング検索条件configpy) の表に従う

### 6.3 TransactionFilter

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `priceMin` | Int? | 最低価格（万円） |
| `priceMax` | Int? | 最高価格（万円） |
| `layouts` | Set\<String\> | 間取りフィルタ |
| `wards` | Set\<String\> | 市区町村フィルタ（都道府県別に階層表示） |
| `stations` | Set\<String\> | 駅名フィルタ |
| `walkMax` | Int? | 推定徒歩上限（分） |
| `areaMin` | Double? | 面積下限（㎡） |
| `builtYearMin` | Int? | 築年下限 |
| `tradePeriods` | Set\<String\> | 取引時期フィルタ（例: "2025Q2"） |

フィルタシートの市区町村表示について。
`TransactionFilterSheet` は市区町村を都道府県別セクション（東京都、神奈川県、埼玉県、千葉県の順）に分けて表示する。
各セクションの「すべて」トグルボタンで、都道府県単位の一括選択と解除ができる。現在の成約データは東京都だけなので、実際に表示されるセクションは東京都の1つである。

**メソッド**

| メソッド | 説明 |
|---------|------|
| `apply(to records: [TransactionRecord]) -> [TransactionRecord]` | フィルタ条件を適用 |

### 6.5 ListingFilter（Equatable, Codable）

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `priceMin` | Int? | 最低価格（万円） |
| `priceMax` | Int? | 最高価格（万円） |
| `includePriceUndecided` | Bool | 価格未定を含む |
| `tsuboUnitPriceMin` | Double? | 坪単価下限（万円/坪） |
| `tsuboUnitPriceMax` | Double? | 坪単価上限（万円/坪） |
| `layouts` | Set\<String\> | 間取りフィルタ |
| `wards` | Set\<String\> | 区フィルタ |
| `stations` | Set\<String\> | 駅名フィルタ |
| `walkMax` | Int? | 徒歩上限（分） |
| `areaMin` | Double? | 面積下限（㎡） |
| `ownershipTypes` | Set\<OwnershipType\> | 権利形態フィルタ |
| `propertyType` | PropertyTypeFilter | 物件種別フィルタ |

**メソッド**

| メソッド | 説明 |
|---------|------|
| `apply(to listings: [Listing]) -> [Listing]` | フィルタ条件を `[Listing]` に適用して絞り込んだ結果を返す。View 側の前処理（お気に入り・座標有無・掲載終了除外など）の後に呼び出す想定。 |
| `extractWard(from address: String?) -> String?` | 住所から区名を抽出（例: "東京都江東区豊洲5丁目" → "江東区"） |
| `availableLayouts(from listings: [Listing]) -> [String]` | 一覧内に存在する間取りの一意リスト（フィルタシートの選択肢用） |
| `availableWards(from listings: [Listing]) -> Set\<String\>` | 一覧内に存在する区名のセット（フィルタシートの選択肢用） |
| `availableRouteStations(from listings: [Listing]) -> [RouteStations]` | 路線別駅名リスト（フィルタシートの選択肢用） |

`RouteStations` は `ListingFilter.swift` で定義する Equatable 構造体で、`routeName` と `stationNames` を持つ。フィルタシートの路線と駅の選択UIが使う。

### 6.6 FilterTemplate

フィルタ条件をテンプレートとして保存するためのモデル。`FilterStore.swift` で定義。

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `id` | UUID | テンプレート ID |
| `name` | String | テンプレート名（ユーザーが命名） |
| `filter` | ListingFilter | 保存されたフィルタ条件 |
| `createdAt` | Date | 作成日時 |

`FilterTemplateStore`（`@Observable`）は、テンプレートの作成、読み取り、更新、削除と、UserDefaultsへの保存を担当する。アプリ全体に `.environment()` で注入する。保存上限は5件（`maxTemplates = 5`）。

### 6.7 CommuteDestinationConfig（Codable, Identifiable）

ユーザーが設定する通勤先。UserDefaults（`commuteDestinations`）にJSONで保存する。`CommuteTimeService` 内で定義する。

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `id` | String | 一意 ID |
| `name` | String | 表示名（例: 会社名） |
| `latitude` | Double | 緯度 |
| `longitude` | Double | 経度 |

**メソッド・静的プロパティ**

| 項目 | 説明 |
|------|------|
| `defaults` | 既定の2か所。アプリバンドルの `CommuteOffices.plist`（`.gitignore` 対象）から読み込む。plistが無い場合はオフィスAとオフィスBのプレースホルダ（座標0,0）を返す |
| `load()` | UserDefaultsから読み込む。空なら `defaults` を返す |
| `save(_:)` | UserDefaults に保存 |
| `coordinate` | CLLocationCoordinate2D を返す computed property |

### 6.8 CommentData

| プロパティ | 型 | 説明 |
|-----------|-----|------|
| `id` | String | コメント ID（UUID） |
| `text` | String | コメント本文 |
| `authorName` | String | 投稿者名 |
| `authorId` | String | 投稿者 ID（Firebase UID） |
| `createdAt` | String | 作成日時（ISO 8601） |
| `editedAt` | String? | 編集日時（ISO 8601）。nil なら未編集 |

### 6.9 ScrapingConfig

スクレイピング条件は、Supabaseの `scraping_config` テーブルの `id = 'default'` の行にある `config` 列（JSONB）が正です。パイプラインの `supabase_config_loader.py` が読み込みます。iOSアプリの `ScrapingConfig` モデルと編集画面は、2026-06-13に削除しました（[docs/refactor-proposals.md](refactor-proposals.md) のP1）。`config` のキーは次のとおりです。

| キー | 型 | 説明 |
|-----------|-----|------|
| `priceMinMan` | Int | 最低価格（万円） |
| `priceMaxMan` | Int | 最高価格（万円） |
| `areaMinM2` | Double | 最低面積（㎡） |
| `areaMaxM2` | Double? | 最高面積（㎡） |
| `walkMinMax` | Int | 徒歩上限（分） |
| `builtYearMin` | Int | 最低築年 |
| `totalUnitsMin` | Int | 最低総戸数 |
| `layoutPrefixOk` | [String] | 間取りプレフィックス |
| `allowedLineKeywords` | [String] | 路線キーワード（空で無効） |
| `allowedStations` | [String] | 対象駅名リスト（空で無効） |
| `toshinWards` | [String] | 都心3区として扱う区名のリスト |
| `waterfrontKeywords` | [String] | 湾岸エリアとして扱う住所キーワードのリスト |

### 6.10 キー定義

| キー名 | 構成要素 | 用途 |
|--------|---------|------|
| identity_key | normalize_listing_name(name)、layout、area_m2、normalized_address、built_year、floor_position（Pythonの `report_utils.identity_key`） | 同一物件の判定。価格、walk_min、total_units、station_name を含まない。住所は丁目レベルに正規化する。floor_position は、両方に値がある場合だけ区別する。iOSの `Listing.identityKey` は、name、layout、area_m2、address、built_year の5項目で、floor_position を含まない |
| listing_key | normalize_listing_name(name)、layout、area_m2、price、normalized_address、built_year（Pythonの `report_utils.listing_key`） | 重複除去。価格を含み、station_name と walk_min を含まない。住所は丁目レベルに正規化する |

---

## 7. Firebase 仕様

Firebaseは一部が現役で残っている。経緯は [docs/refactor-proposals.md](refactor-proposals.md) のP1とP2にある。2026-06-13に、スクレイピング条件のFirestore経路をP1で撤去した。同じ日に、認証、FCM、写真Storageは維持すると決めた（P2）。

| 用途 | 現在の場所 |
|------|-----------|
| ログイン | Firebase Auth（Google サインイン） |
| プッシュ通知 | FCM |
| 内見写真の画像 | Firebase Storage |
| 内見写真のメタデータ | Firestore の `annotations` コレクション |
| パイプライン実行ログ | Firestore の `scraping_logs/latest` |
| いいね、コメント、メモ、チェックリスト | Supabase の `user_annotations`（Firebase Auth の UID を `user_id` に使う） |
| スクレイピング条件 | Supabase の `scraping_config`（6.9 を参照） |
| 物件画像（間取り図、物件写真） | R2。未設定なら Supabase Storage |

### 7.1 Firestore コレクション

#### annotations（内見写真のメタデータ）

`PhotoSyncService` が書き込む。いいねとコメントはSupabaseに保存する。

| フィールド | 型 | 説明 |
|-----------|-----|------|
| ドキュメントID | String | SHA256(identityKey) 先頭16文字 |
| `photos` | Map | 写真IDをキーにした写真メタデータ。値は `fileName`、`authorName`、`authorId`、`createdAt`、`storagePath` |
| `name` | String | 物件名 |
| `updatedAt` | Timestamp | サーバー側の更新日時 |

#### scraping_logs（実行ログ）

| ドキュメント | 内容 |
|------------|------|
| `latest` | 最新のスクレイピングパイプライン実行ログ。`upload_scraping_log.py` が書き込み、iOSの `ScrapingLogService` が読み取る。ログは約900KBで切り詰める（Firestoreのドキュメント上限1MBのため） |

`scraping_config` コレクションは、P1で読み書きの経路を撤去したため使いません。

### 7.2 Firestore セキュリティルール

`firestore.rules` の内容は次のとおりです。

```
annotations/{docId}        → 認証済みユーザーのみ読み書き
scraping_config/{docId}    → 認証済みユーザーのみ読み書き（P1で利用を撤去済み。ルールだけ残っている）
scraping_logs/{docId}      → 認証済みユーザーのみ読み取り（書き込みはルールで許可しない）
```

GitHub Actionsのサービスアカウント（Firebase Admin SDK）は、ルールの制約を受けません。

### 7.3 Firebase Storage ルール

`storage.rules` の内容は次のとおりです。

```
photos/{docId}/{photoId}     → 認証済みユーザーのみ読み書き
                                サイズ上限: 10MB
                                コンテンツタイプ: image/*
floor_plans/{imageId}        → 公開読み取り（認証不要）
property_images/{imageId}    → 公開読み取り（認証不要）
```

`floor_plans/` と `property_images/` のルールは、SUUMO と HOME'S の公開物件写真のキャッシュ用です。ダウンロードトークンが無効になった場合でも、`AsyncImage` が読み込めるように公開読み取りにしています。パイプラインの現在のアップロード先はR2（未設定ならSupabase Storage）で、`upload_floor_plans.py` がFirebase Storageへ書き込むことはありません。

### 7.4 Firebase Cloud Messaging

| 項目 | 詳細 |
|------|------|
| トピック | `new_listings` |
| 送信元 | `enrich-and-report.yml` の finalize ジョブが実行する `scripts/send_push.py`（FCM HTTP v1 API）。変更があった回（`has_changes` が true）に実行する |
| 受信 | iOSアプリ（`PushNotificationService` / `AppDelegate`） |
| 送信内容 | 実行のたびにサイレントプッシュを送る（バックグラウンド同期の契機）。新着または価格変動がある場合だけ、表示される通知を追加で送る |
| 通知の本文 | 新着件数（中古）、中古の内訳、価格変動の件数と物件名のサマリ |

中古の新着は、`is_new_building` フラグで「新規」（初出のマンション）と「別部屋」（既存マンションの別の部屋）に分けます。`price_history` が2件以上あり、最新エントリの日付が当日の物件を、価格変動として検出します。本文の例は「中古 3件（新規2・別部屋1）/ 値下げ 2件（パークタワー -300万、シティタワー -150万）」です。`send_push.py` は新築件数の引数（`--shinchiku-count`）も受け取りますが、新築の取得は廃止済みです。

---

## 8. CI/CD パイプライン

### 8.1 GitHub Actions ワークフロー

パイプラインは、スクレイピング（WF1）と、加工とレポート（WF2）の2つのワークフローで動く。WF2は `workflow_run` トリガーで自動起動する。住まいサーフィンのenrichmentは、レートリミット対策のため `enrich-sumai.yml` に分離している。

#### WF1: Scrape Listings

ファイルは `.github/workflows/scrape-listings.yml` です。

| 項目 | 値 |
|------|------|
| トリガー | 1日4回（`0 0,6,9,11 * * *`。JST 9:00、15:00、18:00、20:00）と `workflow_dispatch`（入力 `send_slack`） |
| Concurrency | `scrape-listings`、`cancel-in-progress: false` |
| timeout-minutes | 60 |
| 出力 | artifact `scrape-results`、`scrape-previous`、`scrape-metadata`、`scrape-caches`（保持1日） |

`scripts/run_scrape.sh` が `main.py --source all --property-type chuko` で中古物件を取得し、`results/latest_raw.json` に出力します。続いて、`results/latest.json` があれば `check_changes.py` で変更の有無を判定する。無ければ変更ありとして扱う。`latest.json` は買い手の個人情報を含むため `.gitignore` 対象で、リポジトリにはコミットされない。結果は `metadata.json`（`has_changes`、`chuko_count`、`is_slack_time`、`date`）に書きます。`is_slack_time` は、起動時刻がUTC 0時台から5時台のときに `true` になります。このワークフローはgit commitをしません。

#### WF2: Enrich and Report

ファイルは `.github/workflows/enrich-and-report.yml` です。

| 項目 | 値 |
|------|------|
| トリガー | `workflow_run`（Scrape Listings の完了。成功した場合のみ処理する）と `workflow_dispatch`（入力 `run_id`、`force`） |
| Concurrency | `enrich-and-report`、`cancel-in-progress: false` |
| ジョブ数 | 5（check、enrich-chuko-core、enrich-chuko-mansion、build-transaction-feed、finalize） |

```
check → has_changes / is_slack_time を判定（timeout: 5分）
  ├── enrich-chuko-core (if: has_changes, continue-on-error, timeout: 120分)
  │   Phase 1: embed_geocode
  │   Phase 2: core トラックの enricher を並列実行
  │            （prep、geocode_hazard、commute、reinfolib、estat、commute_gmaps、homes_images の7トラック）
  │   Phase 3: merge_enrichments.py
  ├── enrich-chuko-mansion (if: has_changes, continue-on-error, timeout: 50分)
  │   mansion トラック（mansion_review_scraper.py）
  ├── build-transaction-feed (if: has_changes, continue-on-error, timeout: 60分)
  └── finalize (if: !cancelled() && (has_changes || is_slack_time), timeout: 75分)
      [has_changes] merge_caches → merge_enrichments → Supabase同期 → upload_floor_plans → post_enrich_dedup → is_newと投資スコアの注入 → sync_db → generate_report → send_push → build_map_viewer → git commit & push
      [is_slack_time] slack_notify（前回通知からの差分を送信。Slack通知は停止中）
```

finalizeの各処理は `scripts/run_finalize.sh` に書かれています。`git add` する対象は `scraping-tool/results/` と、`data/` 配下の一部のキャッシュファイルです。`.gitignore` 対象のファイルは `check-ignore` で除外します。

Slack通知は2026-07-07から全経路を停止しています。`slack_notify.py` は、環境変数 `SLACK_NOTIFICATIONS_ENABLED=1` を設定したときだけ送信します（[README.md](../README.md) を参照）。両ワークフローの失敗通知ステップも `if: false` で無効にしてあります。

両ワークフローは `cancel-in-progress: false` なので、WF2の実行中に新しいWF1が完了しても、実行中のWF2は最後まで走ります。新しいWF2はキューで待ち、現在の実行が終わってから始まる。GitHub Actionsはconcurrency groupごとにキューへ1件しか保持しないため、待機が複数溜まることはない。

`upload_floor_plans.py` はfinalizeジョブで実行します。enrichジョブがタイムアウトしても、enrichedアーティファクトの保存が失われないようにするためです。`ThreadPoolExecutor`（`MAX_WORKERS = 8`）で並列に処理し、`--max-time 20` で時間を制限します。保存先はR2（未設定ならSupabase Storage）です。

`commute_gmaps_enricher.py` のスクレイピング結果キャッシュ（`scraping-tool/commute_gmaps_cache`）は、`actions/cache/restore` と `actions/cache/save`（`if: always()`）でCI実行の間に引き継ぎます。タイムアウトでキャンセルされても、`if: always()` により部分キャッシュが保存される。次回の実行は、未取得の分だけを処理する。

#### Enrich Sumai

ファイルは `.github/workflows/enrich-sumai.yml` です。住まいサーフィンのenrichmentを、1ワーカー、5秒間隔の低負荷で実行します。トリガーは6時間ごと（`30 0,6,12,18 * * *`）、`workflow_run`（Enrich and Reportの完了）、`workflow_dispatch` です。Supabaseへ直接書き込むため、finalizeに依存しません。

#### PRのCIワークフロー

ファイルは `.github/workflows/ci.yml` の1つです。`pull_request` で起動し、`changes` ジョブが変更領域（`scraping-tool/**` はpython、`real-estate-ios/**` はios）を判定します。該当するジョブだけが走り、最後に必ず走る `ci-gate` ジョブが結果を集約して1つのステータスを返します。mainのブランチ保護は、`ci-gate` が緑であることをマージの必須条件にしている。

| ジョブ | 実行する条件 | 処理 |
|--------|-------------|------|
| python-tests | `scraping-tool/**` の変更 | Python 3.11、`pip install -r requirements.txt`、`ruff check .`、`pytest tests/ -v` |
| ios-build | `real-estate-ios/**` の変更 | XcodeGenでプロジェクトを生成し、SPMを解決して、iOSシミュレータでビルドと全テストを実行する（`macos-15`）。Mac Catalystのビルドは、Mac版の廃止（2026-05-16）で削除済み |

#### その他のワークフロー

| ファイル | 内容 |
|---------|------|
| `update-reinfolib-cache.yml` | 8.2 を参照 |
| `storage-image-gc.yml` | 画像ストレージの孤児画像と、掲載終了物件の画像を削除する（毎週、`0 19 * * 0`） |
| `storage-r2-migrate.yml` | Supabase Storage の画像をR2へ移行する（手動実行。手順は [docs/STORAGE_R2_MIGRATION.md](STORAGE_R2_MIGRATION.md)） |
| `supabase-backup.yml` | Supabaseの全テーブルを週次でartifactに退避する（`0 19 * * 0`） |
| `backfill-homes-images.yml` | HOME'Sの画像を補完する（毎日、`30 19 * * *`） |
| `detect-delisted.yml` | Enrich and Report の完了後に、SUUMO詳細ページの掲載終了マーカーを検査する |
| `cron-watchdog.yml` | pg_cronジョブの死活を監視する（毎日、`30 0 * * *`） |
| `notification-watchdog.yml` | Slack通知パイプラインを監視する（`0 1,3 * * *`） |
| `slack-smoke-test.yml` | Slackスレッド返信の動作確認（手動実行） |

`Backfill HOME'S Images`、`Detect Delisted Listings`、`Notification Watchdog`、`Cron Watchdog` の4つは、GitHub側で無効化してあります（[README.md](../README.md) を参照）。

### 8.2 不動産情報ライブラリ・人口動態キャッシュ更新ワークフロー

ファイルは `.github/workflows/update-reinfolib-cache.yml` です。

不動産情報ライブラリAPIとe-Stat APIから、キャッシュデータを事前に構築します。トリガーは毎週月曜 6:00 UTC（`0 6 * * 1`）と `workflow_dispatch`（入力 `target`）です。Enrich and Reportワークフローはこのキャッシュを参照するだけで、これらのAPIを直接呼びません。独自のconcurrency group（`update-reinfolib-cache`）で動くため、他のワークフローと干渉しません。

`fetch_station_prices.py` の直接APIモードは、全ワーカー共通のグローバルレートリミッターを使い、50リクエスト/分（1.2秒間隔）に制限します。不動産情報ライブラリの目安は60リクエスト/分で、それに余裕を持たせた値です。ワークフローのタイムアウトは90分です（初回のフル取得は、809駅 × 5年 ÷ 50リクエスト/分で約81分）。`--resume` により、通常の週次実行は取得済みのデータをスキップして数分で終わります。

`target` が `all` の場合、地価公示と人口動態のキャッシュは、4月の実行と手動実行のときだけ更新します。

| ステップ | 処理 |
|---------|------|
| 1 | `reinfolib_cache_builder.py` → `data/reinfolib_prices.json`、`data/reinfolib_trends.json` |
| 2 | `fetch_station_prices.py` → `data/station_price_history.json` |
| 3 | `reinfolib_land_price_builder.py` → `data/reinfolib_land_prices.json` |
| 4 | `estat_population_builder.py` → `data/estat_population.json` |

`estat_aging_builder.py`（出力は `data/estat_aging.json`）は、このワークフローでは実行しません。

#### 使用するシークレット

| シークレット | 用途 |
|------------|------|
| `SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY` | Supabaseへの書き込み。複数のワークフローが使う |
| `SUMAI_USER`、`SUMAI_PASS` | 住まいサーフィンのログイン（`enrich-sumai.yml`） |
| `FIREBASE_SERVICE_ACCOUNT` | FCM送信と、Firestoreへのログアップロード（`enrich-and-report.yml`） |
| `SLACK_WEBHOOK_URL`、`SLACK_ALERT_WEBHOOK_URL`、`SLACK_HEALTH_WEBHOOK_URL`、`SLACK_BOT_TOKEN`、`SLACK_CHANNEL_ID` | Slack通知（現在は通知を停止中） |
| `REINFOLIB_API_KEY` | 不動産情報ライブラリAPIのキー（`enrich-and-report.yml`、`update-reinfolib-cache.yml`） |
| `ESTAT_API_KEY` | e-StatのアプリケーションID（`update-reinfolib-cache.yml`） |
| `R2_ENDPOINT_URL`、`R2_ACCESS_KEY_ID`、`R2_SECRET_ACCESS_KEY`、`R2_BUCKET_NAME`、`R2_PUBLIC_BASE_URL` | 画像ストレージのR2（`enrich-and-report.yml`、`storage-image-gc.yml`、`storage-r2-migrate.yml`） |
| `ANTHROPIC_API_KEY` | finalizeジョブで使うAnthropic APIのキー（`enrich-and-report.yml`） |
| `PAT_FINALIZE_PUSH` | mainへ直接pushする管理者のPAT（`enrich-and-report.yml`、`detect-delisted.yml`、`storage-image-gc.yml`、`storage-r2-migrate.yml`） |
| `GITHUB_TOKEN` | リポジトリの読み取りと書き込み |

### 8.3 iOS デプロイ（ローカル実行）

**ファイル**: `real-estate-ios/scripts/deploy.sh`

ローカルマシンのCLIで、ビルド番号の更新、アーカイブ、App Store Connectへのアップロードまでを一括で実行します。個人開発のためXcode Cloudは使わず、ローカルデプロイに一本化しています。

TestFlightへの配布は、必ず `./scripts/deploy.sh --ios` で行う。Mac版（Mac Catalyst）は2026-05-16に廃止済みで、`project.yml` は `SUPPORTS_MACCATALYST: "NO"` である。ただし `deploy.sh` には、`--mac`、`--all`、引数なしの実行でMac Catalystを処理するコードがまだ残っているため、これらの実行は避けること。

#### コマンド

| コマンド | 動作 |
|---------|------|
| `./scripts/deploy.sh --ios` | iOSのみ、ビルド番号の更新、アーカイブ、アップロード。通常はこのコマンドを使う |
| `./scripts/deploy.sh --archive` | iOSアーカイブのみ（アップロードしない） |
| `./scripts/deploy.sh --upload` | 既存のiOSアーカイブのアップロードのみ |
| `./scripts/deploy.sh --setup` | API Keyの初回セットアップ（対話式） |
| `./scripts/deploy.sh`、`--all` | iOSとMac Catalystの両方を処理する（Mac版は廃止済みのため使わない） |
| `./scripts/deploy.sh --mac` | Mac Catalystのみ処理する（同上） |

アーカイブの前と、アップロードの前に、`scripts/verify_required_resources.sh` で必須リソースの有無を検証します。

#### ビルド番号の自動管理

`deploy.sh` はアーカイブ時に次の処理を自動で実行します。

1. `project.yml` の `CURRENT_PROJECT_VERSION` を読み取り、1増やす
2. `xcodegen generate` で `.xcodeproj` を再生成する（Info.plistとproject.pbxprojに反映される）
3. Widget拡張の `CFBundleVersion` は `$(CURRENT_PROJECT_VERSION)` を参照するため、自動で同じ番号になる
4. `BUILD_BUMPED` フラグにより、複数のプラットフォームを続けて処理する場合も、番号の更新は1回だけにする

App Store Connectは、同一アプリで未使用のCFBundleVersion（ビルド番号）でないとアップロードを受け付けません。別のマシンやCIで、すでに大きい番号がApp Store Connectに登録されている場合は、`project.yml` の `CURRENT_PROJECT_VERSION` をその最大値以上に手動で合わせてから `deploy.sh` を実行してください。例えば、App Store Connect上のiOSの最新が354なら、354からデプロイして355にします。

エクスポート段階で `xcodebuild` のログに `Upload succeeded` や `EXPORT SUCCEEDED` が出ていても、既存のビルド番号と重複している場合は、処理の後で失敗することがあります。メール通知は必ずしも届かないため、TestFlightまたはApp Store Connectのビルド一覧で確認してください。

#### 前提条件

| 項目 | 詳細 |
|------|------|
| App Store Connect API Key | `~/.config/real-estate-deploy/config` にKey ID、Issuer ID、キーのパスを保存する |
| Apple Distribution 証明書 | キーチェーンに配布用証明書が必要（Xcode → Settings → Accounts → Manage Certificates で作成する） |
| 署名スタイル | Automatic（`-allowProvisioningUpdates` で自動取得する） |
| チームID | `YRP5KV2X62` |
| xcodegen | `brew install xcodegen` でインストールする |

---

## 9. 購入条件・フィルタロジック

### 9.1 スクレイピング検索条件（config.py）

<!-- AUTO:SCRAPING_CONDITIONS:START -->
| 条件 | 値 | 根拠 |
|------|-----|------|
| **エリア** | 東京23区 | — |
| **対象駅** | 未設定 | 対象エリアの限定 |
| **価格** | 7,500万円〜1億1,500万円 | 住み替え前提の投資判断 |
| **面積** | 60㎡以上（上限なし） | 需要の厚いゾーン |
| **間取り** | 2LDK系 / 3LDK系（プレフィックス "2", "3"） | 買い手母集団が厚い |
| **築年** | 実行年 − 30年以降 | 新耐震 + 築浅優先 |
| **駅徒歩** | 10分以内 | — |
| **総戸数** | 20戸以上 | 管理安定性・流動性 |
| **リクエスト間隔** | SUUMO: 2秒 | 負荷軽減 |
| **タイムアウト** | 60秒 / リトライ3回 | 安定性確保 |
| **リトライ戦略（Phase3強化）** | 指数バックオフ（2→4→8→…最大30秒）を HTTP 5xx・接続/読取タイムアウトに適用。429 は `Retry-After` ヘッダー尊重（最大120秒） | ネットワーク耐性 |
| **HOME'S** | **無効**（コード残存、定期実行では未使用） | WAF によりCI/CDパイプラインがタイムアウトするため無効化 |
<!-- AUTO:SCRAPING_CONDITIONS:END -->

### 9.2 Supabase 経由の条件上書き

Supabaseの `scraping_config` テーブルで `id = 'default'` の行に保存された条件は、`supabase_config_loader.py` の `load_config_from_supabase()` が読み込み、`config.apply_runtime_overrides()` でconfigモジュールに反映します。`main.py` と `generate_report.py` は、どちらもこの関数をconfigのimportより前に呼びます。Supabaseのクライアントが無い場合、行が無い場合、取得に失敗した場合は、`config.py` の既定値を使う。その旨はログに出力される。

以前はFirestoreの `scraping_config` とiOSアプリの設定画面から条件を上書きしていましたが、2026-06-13に撤去しました（[7章](#7-firebase-仕様)、[docs/refactor-proposals.md](refactor-proposals.md) のP1）。現在の条件は、migrationとSQLで更新します。

### 9.2.1 設定メタデータの単一ソース化

- 共有ファイルは `real-estate-ios/RealEstateApp/ScrapingConfigMetadata.json` です
- Pythonの `config.py` がこのJSONを読み込み、既定の条件（価格、面積、築年オフセット、駅、路線など）を生成します
- JSONの `constraints` が数値の範囲（価格、面積、徒歩、築年、総戸数）を定義します。Supabaseの値を反映するときの正規化（`_normalize_runtime_config()`）が、この範囲を参照します
- iOSアプリは、このJSONを読み込みません。読み込んでいた `ScrapingConfigService` と `ScrapingConfigView` は、P1で削除しました
- `scraping-tool/scripts/generate_scraping_conditions_doc.py --write-spec` が、9.1の条件表（`AUTO:SCRAPING_CONDITIONS` ブロック）を自動で同期します

### 9.3 iOS アプリのフィルタロジック（共通化）

`ListingFilter.apply(to:)` が物件一覧（ListingListView）と地図（MapTabView）の両方でフィルタ条件を適用する共通メソッドとして使用される。

- **流れ**: View 側で前処理（お気に入りタブ・座標有無・掲載終了除外など）→ `filter.apply(to: baseList)` → View 側で後処理（検索テキスト・ソートなど）
- **ヘルパー**: `availableLayouts(from:)`, `availableWards(from:)`, `availableRouteStations(from:)` がフィルタシートの選択肢データ生成に使用される

### 9.4 購入判断フロー

```
1. 物件候補を20件拾う（駅徒歩/広さ/築年で一次フィルタ）
2. 管理計画認定の有無を必須で確認（対象外は候補から外す）
3. 管理書類で10件に絞る（長期修繕計画・積立・修繕履歴）
4. REINS 成約データで「売れる速度」「価格推移」を見て最終3件
5. 3件のみ内見（現地で売却時の説明コストになる瑕疵を潰す）
```

---

## 10. 非機能要件

### 10.1 パフォーマンス

| 処理 | 最適化手法 |
|------|-----------|
| **データ取得** | 既定のSupabaseモードは、前回同期以降に `updated_at` が変わった物件だけを取得する差分同期。差分の取得と掲載終了キーの取得を、`SupabaseListingStore` が `async let` で並列に実行する。初回は100件/ページで全件を取得する |
| **JSON デコード** | `Task.detached(priority: .userInitiated)` でバックグラウンド |
| **DB 同期** | `identityKey → Listing` の Dictionary で O(1) ルックアップ |
| **304 時 DB 負荷** | JSONフォールバック（`useSupabase` が false のとき）のみ。304 時は `isNew == true` の物件のみ取得し、変更なしなら `pullAnnotations` をスキップする |
| **JSON パースキャッシュ** | `parsedSuumoImages` / `parsedFloorPlanImages` を `ListingJSONCache` でキャッシュ。body 再評価時の冗長デコード回避 |
| **buildingGroupKey** | `@Transient` でキャッシュ。グルーピング時の regex 再計算回避 |
| **通勤時間計算** | `withTaskGroup` で concurrency=2 の並列 MKDirections。バッチ MainActor 更新。大量物件で約 40–50% 高速化 |
| **GeoJSON デコード** | バックグラウンドスレッド |
| **DateFormatter** | `static let` で使い回し |
| **二重更新防止** | `guard !isRefreshing` でガード |
| **ETag** | JSONフォールバック時のみ。304 Not Modified でダウンロードをスキップする |
| **リスト行** | テキストと SF Symbol のみ（画像なし、軽量レンダリング） |

#### 10.1.1 パイプライン速度最適化

| コンポーネント | 最適化 |
|---------------|--------|
| **build_units_cache.py** | `ThreadPoolExecutor(max_workers=4)` で SUUMO 詳細ページの HTTP 取得を並列化。`parse_hashes.json` で HTML ハッシュを保持し、変更なし時は再パースをスキップ。ETag/Last-Modified による条件付きリクエストでキャッシュ済みのHTMLを毎回、帯域効率よく再検証する（`STALE_DAYS = 0`。掲載終了を当日中に検知するため） |
| **sumai_surfin_enricher.py** | `ThreadPoolExecutor(max_workers=3)` で並列 enrichment。各ワーカーが独自セッションでログイン |
| **hazard_enricher.py** | `ThreadPoolExecutor(max_workers=5)` で GSI タイル並列取得。`Lock` でタイルキャッシュをスレッドセーフに |

#### 10.1.2 パイプライン精度改善

| コンポーネント | 改善内容 |
|---------------|----------|
| **report_utils.row_merge_key** | 物件名・価格・間取りに加え address・built_year を含め、異なる建物の誤マージを防止 |
| **parse_utils.parse_monthly_yen** | 円マークなしのカンマ区切り（"18,000"）・純粋数値（"18000"）にフォールバック対応 |
| **parse_utils.extract_ward** | 区名抽出の正規実装。reinfolib_enricher・estat_enricher が委譲し重複実装を排除 |

### 10.2 オフライン動作

| 画面 | オフライン時の挙動 |
|------|-------------------|
| **一覧** | SwiftData キャッシュから表示。更新はエラー表示。 |
| **お気に入り** | ローカルから表示。Supabase への同期は次回オンライン時。 |
| **地図** | キャッシュ済みピン表示。未キャッシュのハザードタイルは非表示。 |
| **設定** | 全項目表示可能。フルリフレッシュはエラー。 |
| **詳細** | ローカルデータ表示。外部リンクはブラウザがオフラインエラー。 |
| **通勤時間** | MKDirections はオフライン不可。キャッシュ済み結果は表示。 |

### 10.3 アクセシビリティ

| 項目 | 対応 |
|------|------|
| **Dynamic Type** | 全画面でシステムフォントスタイル使用、ハードコードサイズなし |
| **VoiceOver** | 一覧行に `accessibilityLabel`（物件名・価格・面積・徒歩）を設定 |
| **色のコントラスト** | セマンティックカラー使用、ライト/ダークモードで自動調整 |
| **タップターゲット** | 最小 44pt |
| **操作ヒント** | `accessibilityHint`（「タップで詳細。ハートでいいね」） |

### 10.4 セキュリティ

| 項目 | 対応 |
|------|------|
| **認証** | Google サインイン + メールホワイトリスト |
| **Firestore** | `annotations` は認証済みユーザーのみ読み書き。`scraping_logs` は認証済みユーザーの読み取りのみ（7.2 を参照） |
| **Firebase Storage** | 内見写真は認証済みユーザーのみ。10MB/画像のみの制限。`floor_plans/` と `property_images/` は公開読み取りで、書き込みルールは無い（7.3 を参照） |
| **Supabase** | いいねやコメントの `user_annotations` と買い手プロフィールは、`SECURITY DEFINER` の RPC 経由でアクセスする。Firebase Auth の UID を `user_id` に使う |
| **Admin SDK** | サービスアカウントは Firestore ルールの制約を受けない |
| **環境変数** | シークレットは GitHub Actions Secrets で管理、`.env` は `.gitignore` |

---

## 11. 用語集

| 用語 | 定義 |
|------|------|
| **listing** | 物件1件のデータ |
| **identity_key** | 同一物件を判定するキー。項目は 6.10 を参照する。物件名の正規化には中黒除去と既知の誤字補正を含む |
| **listing_key** | 重複除去に使うキー。identity_key の項目から所在階を除き、価格を加えたもの。項目は 6.10 を参照する |
| **annotation** | いいね、コメント、メモ、チェックリスト、写真のユーザーデータ。Supabaseの `user_annotations` で家族間共有する。写真のメタデータはFirestore、画像はFirebase Storageに置く |
| **property_type** | `"chuko"`（中古）または `"shinchiku"`（新築）。新築の取得は廃止済み |
| **hazard overlay** | 国土地理院のハザードマップタイルを地図に重畳表示するレイヤー。液状化・揺れやすさは GSI タイル非公開のため治水地形分類図（`lcmfc2`）で代替 |
| **enricher** | スクレイピング後にデータを付加するスクリプト群（通勤・ハザード・住まいサーフィン） |
| **identity_key → docId** | SHA256(identity_key) の先頭16文字。Firestoreの `annotations` コレクション（写真メタデータ）のドキュメントID。identity_key の項目が変わるとdocIdも変わる |
| **ETag** | HTTPキャッシュ制御ヘッダー。304 Not Modified でダウンロードをスキップする。iOSはJSONフォールバック時だけ使う |
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
| `SUMAI_USER` | 住まいサーフィンのユーザー名 | enrich-sumai.yml、sumai_surfin_enricher.py、sumai_surfin_browser.py |
| `SUMAI_PASS` | 住まいサーフィンのパスワード | enrich-sumai.yml、sumai_surfin_enricher.py、sumai_surfin_browser.py |
| `SUPABASE_URL` | SupabaseのURL | 各ワークフロー、supabase_client.py、upload_floor_plans.py |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabaseのservice roleキー | 各ワークフロー、supabase_client.py、run_finalize.sh |
| `USE_SUPABASE_EXPORT` | `1` のとき、finalizeでSupabaseのスナップショットから `latest.json` を作り直す | enrich-and-report.yml、run_finalize.sh |
| `R2_ENDPOINT_URL`、`R2_ACCESS_KEY_ID`、`R2_SECRET_ACCESS_KEY`、`R2_BUCKET_NAME`、`R2_PUBLIC_BASE_URL` | 画像ストレージのR2 | enrich-and-report.yml、image_storage.py |
| `ANTHROPIC_API_KEY` | Anthropic APIのキー | enrich-and-report.yml、claude_client.py |
| `FIREBASE_SERVICE_ACCOUNT` | Firebaseサービスアカウント JSON | enrich-and-report.yml、upload_scraping_log.py、send_push.py |
| `FIREBASE_PROJECT_ID` | FCMのフォールバック | send_push.py |
| `SLACK_WEBHOOK_URL` | Slack Webhook URL | enrich-and-report.yml、slack_notify.py |
| `SLACK_NOTIFICATIONS_ENABLED` | `1` のときだけSlackへ送信する。既定は停止 | slack_notify.py |
| `REINFOLIB_API_KEY` | 不動産情報ライブラリAPIのキー | enrich-and-report.yml、update-reinfolib-cache.yml、reinfolib_cache_builder.py、fetch_station_prices.py、build_transaction_feed.py |
| `ESTAT_API_KEY` | e-StatのアプリケーションID | update-reinfolib-cache.yml、estat_population_builder.py、estat_aging_builder.py |

`SLACK_ALERT_WEBHOOK_URL`、`SLACK_HEALTH_WEBHOOK_URL`、`SLACK_BOT_TOKEN`、`SLACK_CHANNEL_ID`、`PAT_FINALIZE_PUSH` は、ワークフローがGitHub Actionsのシークレットとして参照します。用途は 8.2 の「使用するシークレット」にあります。

---

## 付録 B: ドキュメント相互参照

| ファイル | 内容 |
|---------|------|
| `docs/SPECIFICATION.md` | 本ファイル（総合仕様書） |
| `docs/10year-index-mansion-conditions-draft.md` | 購入条件ドラフト |
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
    "direction": "南",
    "balcony_area_m2": 12.5,
    "parking": "空有 月額20,000円〜25,000円",
    "constructor": "大林組",
    "zoning": "商業地域",
    "repair_fund_onetime": 50000,
    "delivery_date": "即引渡可",
    "feature_tags": ["駅徒歩5分以内", "2沿線以上利用可"],
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
    "commute_info": "{...}",
    "floor_plan_images": ["https://pub-xxxx.r2.dev/floor_plans/abc123def456.jpg"],
    "is_new": false,
    "is_new_building": false
  }
]
```

### C.2 新築マンション（latest_shinchiku.json）

新築の取得は2026-06-03に廃止しました。次の例は廃止前の出力形式で、現在のパイプラインはこのファイルを生成しません（`run_enrich.sh` は `--property-type chuko` だけを受け付けます）。

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
    "ownership": "所有権",
    "property_type": "shinchiku",
    "latitude": 35.6600,
    "longitude": 139.7000,
    "is_new": true,
    "is_new_building": true
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
  "playground": {
    "minutes": 25,
    "summary": "東京メトロ半蔵門線→半蔵門駅 徒歩5分",
    "transfers": 1,
    "calculatedAt": "2025-01-15T10:00:00Z"
  },
  "m3career": {
    "minutes": 30,
    "summary": "（路線→オフィスB最寄駅 徒歩N分）",
    "transfers": 0,
    "calculatedAt": "2025-01-15T10:00:00Z"
  }
}
```
