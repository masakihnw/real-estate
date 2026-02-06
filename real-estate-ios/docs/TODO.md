# TODO・未確定事項

次回作業時にここから着手してください。

---

## 未完了タスク（要作業）

### Firebase セットアップ（必須・最優先）
- [ ] Firebase Console でプロジェクト作成 → [手順書](FIREBASE-SETUP.md)
- [ ] `GoogleService-Info.plist` をダウンロードして上書き
- [ ] Authentication → 匿名認証を有効化
- [ ] Firestore Database を作成（asia-northeast1）
- [ ] 実機で動作確認（いいね・メモの共有）

### アプリアイコン
- [ ] カラースキーム3案から1つを選択（[プレビュー](../color-preview/index.html)で確認）
  - A. Midnight Teal（ダーク・知的）
  - B. Warm Sage（ライト・温かみ）
  - C. Indigo Blueprint（設計図風・洗練）
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

### スクレイピングの自動化（GitHub Actions）
- 現在: `latest.json` の更新タイミングが不明確
- 検討: GitHub Actions で定期的にスクレイピング → `latest.json` 自動更新
- これにより BGAppRefreshTask と組み合わせて完全自動の新着通知パイプラインが完成

### リモートプッシュ通知（Phase 2）
- 現在: BGAppRefreshTask によるローカル通知（OS のスケジュールに依存）
- Phase 2: APNs + バックエンド（Firebase Cloud Functions 等）で即時プッシュ

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
