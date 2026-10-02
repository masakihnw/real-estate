# 物件情報iOSアプリ 要件定義

## 1. 概要

スクレイピング（SUUMO、HOME'Sなど）で取得した中古マンションを、iOSアプリで閲覧する。アプリ内に物件DB（SwiftData）を持ち、新規物件が追加されたときに通知で知らせる。NotionとSlackは本アプリと連携しない。デザインはHIG、OOUI、iOS 26 Liquid Glassに沿い、軽量で見やすいアプリにする。

新築マンションは対象外である。過去に新築タブがあったが、現在はスクレイパーが中古のみを取得し、アプリは同期時に中古以外の物件をローカルから削除する。

---

## 2. 方針

| 項目 | 決定 |
|------|------|
| データ取得 | 既定ではSupabaseから取得する。設定で「Supabase API」をオフにした場合だけ、カスタムURLの一覧JSON（GitHub rawなど）から取得する。詳細は [DB-STRATEGY.md](DB-STRATEGY.md) を参照。 |
| プッシュ通知 | ローカル通知（BGAppRefreshTask）とリモートプッシュ通知（FCM）を使う。GitHub Actionsでスクレイピングした後、新着があれば `scraping-tool/scripts/send_push.py` がFCM HTTP v1 APIでトピック `new_listings` にプッシュする。 |
| Notion | 本アプリでは連携しない。DB機能はアプリに寄せる。 |
| Slack | 本アプリでは連携しない。アプリから通知できれば足りる。 |
| 対象 | iOS 17以降。iPhoneとiPadに対応する（`project.yml` の `TARGETED_DEVICE_FAMILY` は `1,2`）。 |
| ユーザー | 自分用。家族だけがインストールできる配布（TestFlightなど）を想定する。 |
| デザイン | HIGとOOUIに沿う。iOS 26ではLiquid Glassに対応し、iOS 17から25ではシステムのスタイルにフォールバックする。 |
| 共有 | いいねとコメントはSupabaseで家族間共有する。認証はFirebase AuthのGoogleサインインで、Firebase AuthのUIDをSupabaseのuser_idに使う。許可するアカウントは外部plistの `AllowedEmails.plist` で制限する。 |
| 物件種別 | 中古マンションのみ。 |
| 地図 | MapKitで物件ピンを表示する。ハザードマップ（国土地理院タイル）と東京都の地域危険度をオーバーレイする。 |

Firebaseは認証、FCM、内見写真のStorage、スクレイピングログの閲覧（Firestore）に使っている。手順は [FIREBASE-SETUP.md](FIREBASE-SETUP.md) にある。

---

## 3. 機能要件

### 3.1 実装済み

- 物件一覧（中古）: アプリ内DBに保存された中古物件を一覧表示する。
- ソート: 追加日（新しい順）、価格（安い順と高い順）、徒歩（近い順）、広さ（広い順）。
- フィルタ: 価格（範囲）、間取り（複数選択）、駅（路線別、複数選択）、駅徒歩（分以内）、専有面積（㎡以上）、権利形態。権利形態は所有権と定期借地のチェックボックスで選ぶ。
- 物件詳細: 一覧で1件タップすると表示する。外部ブラウザでSUUMOやHOME'Sの詳細ページを開ける。
- いいね: 各物件にいいねを付けたり外したりできる。一覧、詳細、地図のどこからでも操作できる。
- コメント: 各物件にコメントを付け、家族間で共有する。作成者名を表示し、自分のコメントは編集と削除ができる。
- マイリストタブ: いいね済みの物件だけを表示する。
- 新規物件の通知: 新規物件が追加されたときにローカル通知とFCMのリモートプッシュで知らせる。
- バックグラウンド自動取得: BGAppRefreshTaskで定期的にデータを取得し、新着を検出して通知する。
- データの同期: 更新ボタンやpull-to-refreshで最新の物件リストを取得し、ローカルDBを更新する。フォアグラウンドに戻ったとき、前回の取得から15分以上たっていれば自動で更新する。
- テキスト検索（F1）: 物件名のインクリメンタル検索（`.searchable`）。
- 駅名フィルタ（F2）: FilterSheet内の駅名アコーディオンで、路線別に駅名チップを複数選択できる。
- 物件比較（F3）: ツールバーから比較モードを起動し、最大4件を横並びで比較する（`ComparisonView`）。
- CSVエクスポート（F5）: お気に入り物件をShareLinkでCSVにして共有する。
- 共有フィルタ（U2）: FilterStoreでフィルタ状態を全タブで共有する実装として完了した。現在は中古一覧（`ListingListView`）と地図（`MapTabView`）がそれぞれ独立した `FilterStore` を持ち、タブ間では共有しない。
- 現在地表示（U4）: 地図タブ左下の現在地ボタンで、MapKitの現在地表示を切り替える。
- 空状態（U5）: 「今すぐ更新」ボタン付きの空状態画面で、初回ユーザーを案内する。
- 更新時刻の表記（U6）: 更新時刻を `HH:mm` 形式で表示する。

### 3.2 タブ構成と地図

- ボトムタブは「今日」「さがす」「マイリスト」「設定」の4つ。iPadなど横幅が広い環境では、同じ4項目をNavigationSplitViewのサイドバーに並べる。
- 「さがす」タブはセグメントでリストと地図を切り替える。
- 地図: MapKitで物件をピン表示する。
  - ピンをタップするとポップアップ（物件概要といいねボタン）が開き、タップすると詳細画面に遷移する。
  - 一覧と同じフィルタ条件で絞り込める。
- ハザードマップオーバーレイ: 国土地理院のタイルを地図に重ねる。レイヤーごとに表示と非表示を切り替えられる。
  - 洪水浸水想定、土砂災害警戒、高潮浸水想定、津波浸水想定、液状化（地形分類）、地盤の揺れやすさ。
  - 内水浸水想定、浸水継続時間、家屋倒壊（氾濫流）、家屋倒壊（河岸侵食）。
- 地域危険度オーバーレイ（東京都）: 東京都都市整備局の地域危険度（建物倒壊、火災、総合）をGeoJSONからMKPolygonに変換する。ランク1から5で色分けする。GeoJSONは `scraping-tool/results/risk_geojson/` に置く。
- リモートプッシュ通知: トピック `new_listings` を購読する。スクレイピングで新着を検出すると、GitHub ActionsからFCMで送信する。

### 3.3 一覧に表示する情報

- 物件名、価格、間取り、専有面積、駅徒歩
- 築年数、階数と階建て、所有権か定借か、総戸数
- 路線と駅名
- コメントの件数（吹き出しアイコンと件数、コメントがあるとき）、いいねアイコン

### 3.4 未実装

- カラースキームの切り替え。ユーザー指示により不要と判断した（[TODO.md](TODO.md) のスキップ項目を参照）。

---

## 4. 非機能要件

- 軽い: 起動が速く、一覧のスクロールがなめらかである。
- 見やすい: 情報密度を抑え、フォント、余白、階層を整理したUIにする。
- オフライン: 一度取得した一覧は、オフラインでも閲覧できる。詳細ページのURLはオンライン時だけ開ける。

---

## 5. データ

### 5.1 中古マンション

- Supabaseから取得する。設定で「Supabase API」をオフにした場合は、カスタムURLの一覧JSONを取得する。
- `property_type` は `"chuko"` を設定する。
- 主なキーは `name`、`url`、`address`、`price_man`、`area_m2`、`layout`、`built_year`、`station_line`、`walk_min`、`floor_position`、`floor_total`、`total_units`、`ownership`、`source`、`list_ward_roman` など。

### 5.2 共通

- 新規判定は `identity_key` で行う。アプリは、Supabaseが計算した `supabaseIdentityKey` を優先して同期のマッチングに使う。
- ユーザーデータ（`isLiked`、コメント、`addedAt`）はローカルのSwiftDataとSupabaseで管理する。同期のときに物件データ由来の値で上書きしない。

---

## 6. 想定アーキテクチャ

- アプリ: SwiftUIとSwiftDataでローカルに永続化する。タブは今日、さがす（リストと地図）、マイリスト、設定。HIG、OOUI、Liquid Glass（iOS 26）、システムスタイル（iOS 17から25）。
- データ同期: 既定ではSupabaseから差分を取得し、SwiftDataを更新する。同一物件は `identityKey` でマッチして更新し、新規は挿入し、掲載終了した物件はローカルから削除する。
- 通知: BGAppRefreshTaskがバックグラウンドで自動取得する（最短間隔30分、実行タイミングはOSが決める）。FCMのリモートプッシュ通知（GitHub Actions、FCM HTTP v1 API、トピック送信）も使う。
- 共有: いいねとコメントはSupabaseのRPCで読み書きする（`SupabaseAnnotationService`）。内見写真はFirebase StorageとFirestoreで共有する。
- 地図: MapKit、MKTileOverlay（国土地理院のハザードタイル10種）、MKPolygon（東京都地域危険度のGeoJSON）、CLGeocoderとMapKitのジオコーディング。
- スクレイピング: SUUMOやHOME'Sなどの中古物件をGitHub Actionsで取得し、Supabaseに同期する。

---

## 7. ドキュメント一覧

| ファイル | 内容 |
|---------|------|
| [REQUIREMENTS.md](REQUIREMENTS.md) | 本ファイル。要件定義。 |
| [DB-STRATEGY.md](DB-STRATEGY.md) | ローカルDB（SwiftData）の設計と同期方針。 |
| [DESIGN.md](DESIGN.md) | HIG、OOUI、Liquid Glassのデザイン指針。 |
| [FIREBASE-SETUP.md](FIREBASE-SETUP.md) | Firebaseプロジェクトのセットアップ手順。 |
| [TODO.md](TODO.md) | 実装の完了履歴と未確定事項。 |

---

## 8. 用語

- listing: 物件1件のデータ。
- identity_key: 物件を一意にするキー。価格、駅名、徒歩は含めない。スクレイパー側（`scraping-tool/report_utils.py`）は名前、間取り、専有面積、住所、築年、所在階の6項目で、iOS側（`Listing.identityKey`）は所在階を除く5項目で作る。
- 新規: 前回の取得リストに `identity_key` が存在しなかった物件。
- annotation: いいねとコメントのユーザーデータ。Supabaseで家族間共有する。
- property_type: `"chuko"`（中古）。
- hazard overlay: 国土地理院のハザードマップタイルを地図に重ねて表示するレイヤー。

---

## オフライン動作

| 画面 | オフライン時の挙動 |
|---|---|
| 一覧 | SwiftDataにキャッシュされた最新データを表示する。更新ボタンとpull-to-refreshは「オフラインのため取得できません。接続を確認してください。」というエラーを出す。 |
| マイリスト | ローカルのSwiftDataから表示する。いいねとコメントはローカルに保存済みで、Supabaseとの同期は次回の更新時に実行する。 |
| 地図 | キャッシュ済みの物件ピンを表示する。ハザードマップタイルはMapKitのキャッシュに依存し、未キャッシュ分は表示されない。 |
| 設定 | 全項目を表示できる。フルリフレッシュは上記のエラーを返す。 |
| 詳細 | ローカルデータで表示する。外部リンク（SUUMOやHOME'S）はブラウザがオフラインエラーを表示する。 |
| 通勤時間 | 経路計算にMKDirections（ネットワーク必須）を使うため、オフライン時は計算できない。キャッシュ済みの経路は表示できる。 |

### ETagキャッシュ

対象は、カスタムURLからJSONを取得する経路（「Supabase API」をオフにした場合）だけである。Supabaseから取得する既定の経路には適用しない。

- サーバーから `ETag` ヘッダーを受信した場合は `UserDefaults` に保存する。
- 次回のリクエストでは `If-None-Match` ヘッダーで送信する。
- サーバーが `304 Not Modified` を返した場合は、ダウンロードをスキップして通信量を減らす。
- フルリフレッシュはETagをクリアして全件を再取得する。

---

## アクセシビリティ対応

| 項目 | 対応状況 |
|---|---|
| Dynamic Type | 多くの画面でシステムフォントスタイル（`.headline`、`.subheadline`、`.caption` など）を使う。`RealEstateApp` 配下には `.system(size:)` が73箇所残っており、置き換えは完了していない（2026-10-02 時点。[IMPROVEMENT-LIST.md](IMPROVEMENT-LIST.md) の D2 を参照）。 |
| VoiceOver | 一覧行に `accessibilityLabel`（物件名、価格、面積、徒歩）を設定する。ボタン類にも `accessibilityLabel` を付ける。 |
| 色のコントラスト | セマンティックカラー（`.primary`、`.secondary`、`.accentColor`）を使い、ライトモードとダークモードで自動調整する。 |
| ボタンサイズ | タップターゲットは最小44ptを目安に設定する。 |
| 操作ヒント | 一覧行に `accessibilityHint` を設定する（「タップで詳細。ハートでいいね」）。 |

---

## パフォーマンス

| 処理 | 最適化手法 |
|---|---|
| データ取得 | Supabaseの差分取得と掲載終了キーの取得を `async let` で並列に実行する。ネットワーク待ちが短くなる。 |
| JSONデコード | `Task.detached(priority: .userInitiated)` でバックグラウンドスレッドに移し、UIのフリーズを防ぐ。 |
| DB同期 | `identityKey` から `Listing` を引くDictionaryでO(1)のルックアップにする。従来のO(N*M)がO(N+M)になる。 |
| GeoJSON | バックグラウンドスレッドでデコードする。 |
| DateFormatter | `static let` で使い回し、毎回の生成を避ける。 |
| 二重更新の防止 | `guard !isRefreshing` で同時リフレッシュを防ぐ。 |
| ETag | 304 Not Modifiedでダウンロード自体をスキップする（JSON経路のみ）。 |
