# TODO・未確定事項

次回作業時にここから着手してください。

---

## 対応順序（優先度順）

### Phase 1: 新築スクレイピング基盤
- [x] 1. SUUMO 新築スクレイパー作成（`suumo_shinchiku_scraper.py`）
- [x] 2. HOME'S 新築スクレイパー作成（`homes_shinchiku_scraper.py`）
- [x] 3. `main.py` に `--property-type` フラグ追加
- [x] 4. `update_listings.sh` に新築ステップ追加
- [x] 5. GitHub Actions ワークフロー更新

### Phase 2: iOS アプリ - データモデル拡張
- [x] 6. `Listing.swift` に `propertyType`, `priceMaxMan`, `areaMaxM2`, `deliveryDate` 追加
- [x] 7. `ListingStore.swift` に新築用 JSON URL 対応（複数ソース同期）
- [x] 8. `ListingDTO` 拡張

### Phase 3: iOS アプリ - タブ再構成
- [x] 9. ボトムタブ変更: 中古 | 新築 | 地図 | お気に入り | 設定
- [x] 10. `ListingListView` に `propertyType` フィルタ追加

### Phase 4: iOS アプリ - 地図タブ
- [x] 11. `MapTabView.swift` 作成（MapKit + 物件ピン）
- [x] 12. ピンタップ → ポップアップ（概要 + いいね）→ 詳細遷移
- [x] 13. 中古一覧と同じフィルタ条件を地図にも適用
- [x] 14. 新築/中古を色分けして両方表示

### Phase 5: iOS アプリ - ハザードマップ
- [x] 15. 国土地理院 WMS タイルオーバーレイ（洪水・土砂・高潮・津波・液状化）
  - UIViewRepresentable で MKMapView をラップし、MKTileOverlay で国土地理院タイルを描画
- [x] 16. レイヤー表示/非表示切替 UI
  - ハザードマップシートで各レイヤーをトグル、アクティブレイヤーを凡例表示

### Phase 6: iOS アプリ - 地域危険度
- [x] 17. 地域危険度データのオーバーレイ
  - 国土地理院配信の地盤振動タイル（13_jibanshindou）を利用

### Phase 7: ジオコーディング改善
- [x] 18. MapKit ジオコーダー + SwiftData キャッシュ
  - CLGeocoder でバッチジオコーディング、結果を Listing.latitude/longitude に保存

### Phase 8: Xcode プロジェクト設定 ✅ 完了
- [x] Google Sign-In URLスキーム（`CFBundleURLTypes`）を `Info.plist` / `project.yml` に追加
- [x] `Assets.xcassets` 作成（`AppIcon.appiconset` + `AccentColor.colorset`）
- [x] `TARGETED_DEVICE_FAMILY` 不一致修正（XcodeGen 再生成）

### Phase 9: Firebase セットアップ ✅ 完了
- [x] Firebase Console でプロジェクト作成（`real-estate-app-5b869`）
- [x] `GoogleService-Info.plist` をダウンロードして配置
- [x] Authentication → Google ログインプロバイダの有効化
- [x] Firestore Database を作成（asia-northeast1）
- [x] Firestore セキュリティルール（テストモード → 本番ルール）

### Phase 10: APNs + FCM セットアップ ✅ 完了
- [x] Apple Developer Console で APNs 認証キー (.p8) 作成
- [x] Firebase Console → Cloud Messaging に APNs キーをアップロード
- [x] GitHub リポジトリに `FIREBASE_SERVICE_ACCOUNT` シークレット設定

### Phase 11: 地域危険度 GeoJSON ✅ 完了
- [x] `convert_risk_geojson.py` 実行 → GeoJSON 生成・コミット

### Phase 12: アプリアイコン（一部完了）
- [x] カラースキーム選択 → A. Blue（#007AFF）を採用
- [x] Gemini で画像生成（虫眼鏡+マンションシルエット、Blue #007AFF）
- [x] 生成された 1024x1024 PNG を `Assets.xcassets/AppIcon.appiconset/` に配置し `Contents.json` を更新
- [ ] 選択したカラースキームを `DesignSystem.swift` に適用

### Phase 13: ハイブリッド改善（データ取得最適化） ✅ 完了
- [x] デフォルト URL をアプリにハードコード（初回 URL 設定不要）
- [x] ETag ベース差分チェック（未変更なら全件ダウンロードをスキップ）
- [x] GitHub Actions 更新頻度を1日4回に増加（JST 06:00 / 12:00 / 19:00 / 00:00）
- [x] Settings 画面改善（カスタム URL は「詳細設定」に折りたたみ、ステータス表示追加）
- [x] フルリフレッシュ機能（ETag キャッシュクリア → 全件再取得）

### Phase 14: バグ修正・UX改善・パフォーマンス最適化 ✅ 完了

#### Critical バグ修正
- [x] 地図いいねボタンの保存バグ修正（`modelContext.save()` 未呼び出し）
- [x] `try!` クラッシュリスク修正（`do/catch` + `fatalError` に変更）
- [x] 更新ボタンがデフォルト URL 利用時に無効化されるバグ修正
- [x] GitHub Actions commit ステップの件数カウントバグ修正

#### UX 改善
- [x] 東京都地域危険度 GeoJSON のデフォルト URL 設定（設定不要で表示可能に）
- [x] プッシュ通知タップ → 中古タブへ自動遷移
- [x] メモ Firestore 書き込みデバウンス（0.8秒、毎キーストローク送信を防止）
- [x] エラーメッセージ表示改善（ツールバーアイコン + アラートで全文表示）
- [x] 空状態メッセージを「更新ボタンをタップして〜」に変更
- [x] FCM トークンログを `#if DEBUG` ガード

#### パフォーマンス最適化
- [x] ListingStore: `#Predicate` による propertyType フィルタ（全件フェッチ → 対象のみ）
- [x] FirebaseSyncService: Firestore IN クエリでバッチ取得（全ドキュメント取得 → 対象のみ）
- [x] ジオコーディング: TaskGroup による2並列化（直列 → 約2倍速）
- [x] ハザードマップオーバーレイ: 差分更新（毎 render 全削除再追加 → 変更時のみ）

#### スクレイピングツール改善
- [x] HOME'S スクレイパーに 5xx エラーリトライ追加（SUUMO と同等）
- [x] 全スクレイパーに 429 レートリミット処理追加（`Retry-After` 対応）
- [x] `check_changes.py`: 価格以外の属性変更も検知（`listing_has_property_changes` 使用）
- [x] SUUMO/HOME'S 並列スクレイピング（`ThreadPoolExecutor` で約2倍速）
- [x] FCM プッシュ通知送信にリトライ追加（最大3回、指数バックオフ）
- [x] GitHub Actions: スクレイピング失敗時の Slack 通知ステップ追加

---

## 未確定仕様

### Firebase Firestore 同期の競合解決
- 現在: Firestore 側の値を常にローカルに上書き（last-write-wins）
- 検討: 同時編集が起きた場合の `updatedAt` ベースのマージ（現状は家族少人数なので問題にならない想定）

### Firestore セキュリティルール ✅ 設定済み
- ~~現在: テストモード（30日で期限切れ）~~
- 認証済みユーザーのみ read/write のルールに変更済み

### リモートプッシュ通知 ✅ 設定完了
- FCM (Firebase Cloud Messaging) を GitHub Actions から直接送信
- トピック `new_listings` を購読、新着検出時にプッシュ
- APNs 認証キー (.p8) を Firebase Console にアップロード済み
- サービスアカウント JSON を GitHub Actions の `FIREBASE_SERVICE_ACCOUNT` secret に設定済み

### 自治体独自ハザード情報 ✅ 設定完了
- GSI 追加タイルレイヤー（内水浸水、浸水継続時間、家屋倒壊（氾濫流/河岸侵食））
- 東京都地域危険度（建物倒壊/火災/総合）GeoJSON オーバーレイ
- GeoJSON 生成・コミット済み

---

## 実装済み機能一覧

- [x] 物件一覧表示（SwiftData）
- [x] 物件詳細表示
- [x] 外部ブラウザで SUUMO/HOME'S を開く
- [x] データ同期（GitHub raw JSON → SwiftData）
- [x] 新着物件のローカル通知
- [x] BGAppRefreshTask によるバックグラウンド自動取得
- [x] いいね機能
- [x] メモ機能
- [x] お気に入りタブ
- [x] ソート（追加日・価格・徒歩・広さ）
- [x] フィルタ（価格・間取り・駅（路線別）・徒歩・面積・所有権/定借）
- [x] 築年数表示
- [x] 追加日プロパティ（ソート用）
- [x] Firebase Firestore によるいいね・メモの家族間共有（セットアップ完了）
- [x] iOS 26 Liquid Glass / iOS 17-25 Material フォールバック
- [x] HIG・OOUI 準拠のデザイン
- [x] 新築マンションスクレイパー（SUUMO + HOME'S）
- [x] 新築/中古タブ分離
- [x] 地図タブ（MKMapView UIViewRepresentable + ハザードマップタイルオーバーレイ + 地域危険度 + 物件ピン）
- [x] ジオコーディング改善（CLGeocoder + SwiftData キャッシュ）
- [x] 物件詳細画面の新築対応（引渡時期表示、種別表示）
- [x] FCM リモートプッシュ通知（GitHub Actions → FCM HTTP v1 API → トピック送信）
- [x] GSI 追加ハザードレイヤー（内水浸水・浸水継続時間・家屋倒壊氾濫流/河岸侵食）
- [x] 東京都地域危険度 GeoJSON オーバーレイ（建物倒壊・火災・総合、ランク1-5色分け）
- [x] `convert_risk_geojson.py`（Shapefile → GeoJSON 変換スクリプト）
- [x] `send_push.py`（FCM HTTP v1 API プッシュ通知スクリプト）
- [x] Google Sign-In URLスキーム設定（`CFBundleURLTypes`）
- [x] `Assets.xcassets` / `AppIcon.appiconset` 作成
- [x] デフォルト URL ハードコード（初回セットアップ不要化）
- [x] ETag ベース差分チェック（条件付き GET による通信量削減）
- [x] GitHub Actions 更新頻度 1日4回（JST 06:00 / 12:00 / 19:00 / 00:00）
- [x] Settings 画面リニューアル（ステータス表示 + カスタム URL 折りたたみ）
- [x] 地図いいね保存バグ修正 / `try!` 安全化 / 通知タップ遷移 / メモデバウンス
- [x] Predicate 最適化 / Firestore バッチ取得 / ジオコーディング並列化 / オーバーレイ差分更新
- [x] スクレイパー 5xx/429 リトライ / 並列スクレイピング / 変更検知改善 / 失敗時 Slack 通知
- [x] **Phase 15: 非機能改善・UX 強化**
  - [x] N1: BackgroundRefresh の ModelContext を @MainActor で作成（スレッド安全性）
  - [x] N2: APNs 環境を Debug=development / Release=production に自動切替
  - [x] N3: URLSession にタイムアウト設定（リクエスト30秒、リソース60秒）
  - [x] N4: SwiftData save 失敗時のエラーハンドリング強化
  - [x] N5: Dynamic Type 対応（ハードコードフォントサイズを Text Style に置換）
  - [x] N6: オフライン / タイムアウト時の日本語エラーメッセージ表示
  - [x] F1: 新築価格フィルタの範囲交差判定修正（priceMan〜priceMaxMan）
  - [x] F2: いいね / メモ付き物件の自動削除保護
  - [x] F3: 初回起動時にデータを自動取得
  - [x] F4: フォアグラウンド復帰時に15分経過していたら自動更新
  - [x] F5: フィルタ結果ゼロ件時の専用 UI（リセットボタン付き）
  - [x] F6: ソート安定性改善（同値時は名前でタイブレーク）
  - [x] F7: 地図タブにリフレッシュボタン追加
  - [x] F8: タブ選択を @SceneStorage で永続化
  - [x] F9: 物件詳細画面に ShareLink（共有）ボタン追加
  - [x] F10: REQUIREMENTS.md の認証方式を Google サインインに更新
  - [x] F11: 地図で座標未取得物件数を表示
- [x] **Phase 16: パフォーマンス最適化・バグ修正**
  - [x] P1: fetchAndSync の既存物件ルックアップを O(n×m) → Dictionary O(n+m) に最適化
  - [x] P2: 中古/新築データを async let で並列取得（ネットワーク・デコード部分）
  - [x] P3: JSON デコードを Task.detached でバックグラウンド実行（UI フリーズ防止）
  - [x] P4: DateFormatter を static 共有化（一覧スクロール時のアロケーション削減）
  - [x] P6: refresh の二重実行ガード追加（isRefreshing チェック）
  - [x] P7: GeoJSON デコードをバックグラウンド実行（地図タブのフリーズ防止）
  - [x] B1: スクレイパー 429 全リトライ失敗時の `raise None` クラッシュ修正（全4ファイル）
  - [x] B2: update_listings.sh で新築の変更チェックを追加（中古変更なしでも新築更新を反映）
  - [x] B3: BackgroundRefreshManager の Task.result 例外処理を修正
  - [x] B4: メモデバウンス Task を onDisappear でキャンセル + 最終状態を即同期
  - [x] U1: 地図ピン吹き出しボタンに VoiceOver アクセシビリティラベル追加

---

## 手動セットアップ手順

### ✅ 完了済み

- A. APNs 認証キー (.p8) 作成 → Firebase 登録
- B. Firebase Console 設定（Authentication / Firestore）
- C. Firestore セキュリティルール
- D. GitHub Actions シークレット（`FIREBASE_SERVICE_ACCOUNT`）
- F. 地域危険度 GeoJSON 変換

### 未対応: アプリアイコン設定

1. `real-estate-ios/color-preview/index.html` をブラウザで開いてカラースキームを選ぶ
2. 選んだスキームのプロンプトで DALL-E / Midjourney でアイコン画像を生成
3. 1024x1024 の PNG を `RealEstateApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png` として保存
4. `AppIcon.appiconset/Contents.json` を以下に更新:

```json
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

5. 選択したカラースキームを `DesignSystem.swift` に適用
