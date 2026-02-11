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

### Phase 8: Firebase セットアップ（ユーザー手動作業）
- [ ] Firebase Console でプロジェクト作成 → [手順書](FIREBASE-SETUP.md)
- [ ] `GoogleService-Info.plist` をダウンロードして上書き
- [ ] Authentication → 匿名認証を有効化
- [ ] Firestore Database を作成（asia-northeast1）
- [ ] 実機で動作確認（いいね・メモの共有）

### Phase 9: アプリアイコン（ユーザー手動作業）
- [ ] カラースキーム3案から1つを選択（[プレビュー](../color-preview/index.html)で確認）
- [ ] 選択したプロンプトで画像生成（DALL-E / Midjourney）
- [ ] 生成されたアイコンを Assets に設定
- [ ] 選択したカラースキームを `DesignSystem.swift` に適用

---

## 未確定仕様

### Firebase Firestore 同期の競合解決
- 現在: Firestore 側の値を常にローカルに上書き（last-write-wins）
- 検討: 同時編集が起きた場合の `updatedAt` ベースのマージ（現状は家族少人数なので問題にならない想定）

### Firestore セキュリティルール
- 現在: テストモード（30日で期限切れ）
- 対応: 期限前に認証済みユーザーのみ read/write のルールに変更（手順書に記載済み）

### リモートプッシュ通知（Phase 10）
- 現在: BGAppRefreshTask によるローカル通知（OS のスケジュールに依存）
- Phase 10: APNs + バックエンド（Firebase Cloud Functions 等）で即時プッシュ

### 自治体独自ハザード情報
- 国土地理院の全国共通タイルに加え、各自治体が独自に公開するハザード情報がある
- 23区ごとの独自マップは追加調査が必要（Phase 後続で対応検討）

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
- [x] Firebase Firestore によるいいね・メモの家族間共有（セットアップ待ち）
- [x] iOS 26 Liquid Glass / iOS 17-25 Material フォールバック
- [x] HIG・OOUI 準拠のデザイン
- [x] 新築マンションスクレイパー（SUUMO + HOME'S）
- [x] 新築/中古タブ分離
- [x] 地図タブ（MKMapView UIViewRepresentable + ハザードマップタイルオーバーレイ + 地域危険度 + 物件ピン）
- [x] ジオコーディング改善（CLGeocoder + SwiftData キャッシュ）
- [x] 物件詳細画面の新築対応（引渡時期表示、種別表示）
