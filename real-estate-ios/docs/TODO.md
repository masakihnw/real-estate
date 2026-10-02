# TODO・実装の完了履歴

この文書は、実装の完了履歴と、未着手の項目を記録する。現在の仕様は [REQUIREMENTS.md](REQUIREMENTS.md) を参照する。

履歴のうち、次の機能は後から撤去または置き換えられた。該当する項目には「現在は」の注記を付けている。

- 新築マンション: 新築物件の表示、取得、処理は廃止し、中古のみにした。新築のスクレイパーは削除済みである。
- Firestoreによるいいね、メモ、コメントの共有: `FirebaseSyncService` を削除し、`SupabaseAnnotationService` に置き換えた。
- Firestoreの `scraping_config` と、アプリの設定編集画面: 撤去済みである（[リファクタリング提案書](../../docs/refactor-proposals.md) のP1）。

未着手として残る項目は、末尾「スキップ」節の駅名パースのテスト（I6）である。Dynamic Typeの置き換え（N5、D2）は未完了である。`.system(size:)` が73箇所残っている（2026-10-02 時点）。単体テスト（N1）は `RealEstateAppTests` に追加済みである。

---

## 対応順序

### Phase 1: 新築スクレイピング基盤（現在は新築を廃止）
- [x] 1. SUUMO新築スクレイパー作成（`suumo_shinchiku_scraper.py`、現在は削除済み）
- [x] 2. HOME'S新築スクレイパー作成（`homes_shinchiku_scraper.py`、現在は削除済み）
- [x] 3. `main.py` に `--property-type` フラグ追加（現在は `chuko` のみ指定できる）
- [x] 4. `update_listings.sh` に新築ステップ追加（現在は新築のステップなし）
- [x] 5. GitHub Actionsワークフロー更新

### Phase 2: iOSアプリ データモデル拡張
- [x] 6. `Listing.swift` に `propertyType`、`priceMaxMan`、`areaMaxM2`、`deliveryDate` 追加
- [x] 7. `ListingStore.swift` に新築用JSON URL対応（複数ソース同期）。現在は新築用URL（`shinchikuListURL`）を削除済み。
- [x] 8. `ListingDTO` 拡張

### Phase 3: iOSアプリ タブ再構成
- [x] 9. ボトムタブを「中古、新築、地図、お気に入り、設定」に変更。現在は「今日、さがす、マイリスト、設定」の4タブ。
- [x] 10. `ListingListView` に `propertyType` フィルタ追加

### Phase 4: iOSアプリ 地図タブ
- [x] 11. `MapTabView.swift` 作成（MapKitと物件ピン）
- [x] 12. ピンをタップするとポップアップ（概要といいね）が開き、詳細に遷移する
- [x] 13. 中古一覧と同じフィルタ条件を地図にも適用
- [x] 14. 新築と中古を色分けして両方表示（現在は中古のみ）

### Phase 5: iOSアプリ ハザードマップ
- [x] 15. 国土地理院WMSタイルのオーバーレイ（洪水、土砂、高潮、津波、液状化）
  - UIViewRepresentableでMKMapViewをラップし、MKTileOverlayで国土地理院タイルを描画
- [x] 16. レイヤーの表示と非表示を切り替えるUI
  - ハザードマップシートで各レイヤーをトグルし、アクティブなレイヤーを凡例表示

### Phase 6: iOSアプリ 地域危険度
- [x] 17. 地域危険度データのオーバーレイ
  - 国土地理院配信の地盤振動タイル（`13_jibanshindou`）を利用

### Phase 7: ジオコーディング改善
- [x] 18. MapKitジオコーダーとSwiftDataキャッシュ
  - CLGeocoderでバッチジオコーディングし、結果を `Listing.latitude` と `Listing.longitude` に保存

### Phase 8: Xcodeプロジェクト設定（完了）
- [x] Google Sign-InのURLスキーム（`CFBundleURLTypes`）を `Info.plist` と `project.yml` に追加
- [x] `Assets.xcassets` 作成（`AppIcon.appiconset` と `AccentColor.colorset`）
- [x] `TARGETED_DEVICE_FAMILY` の不一致を修正（XcodeGen再生成）

### Phase 9: Firebaseセットアップ（完了）
- [x] Firebase Consoleでプロジェクト作成（`real-estate-app-5b869`）
- [x] `GoogleService-Info.plist` をダウンロードして配置
- [x] AuthenticationでGoogleログインプロバイダを有効化
- [x] Firestore Databaseを作成（`asia-northeast1`）
- [x] Firestoreセキュリティルールをテストモードから本番ルールに変更

### Phase 10: APNsとFCMのセットアップ（完了）
- [x] Apple Developer ConsoleでAPNs認証キー（.p8）を作成
- [x] Firebase ConsoleのCloud MessagingにAPNsキーをアップロード
- [x] GitHubリポジトリに `FIREBASE_SERVICE_ACCOUNT` シークレットを設定

### Phase 11: 地域危険度GeoJSON（完了）
- [x] `convert_risk_geojson.py`（現在のパスは `scraping-tool/scripts/`）を実行し、GeoJSONを生成してコミット

### Phase 12: アプリアイコン（完了）
- [x] カラースキームを選び、A. Blue（#007AFF）を採用
- [x] Geminiで画像生成（虫眼鏡とマンションのシルエット、Blue #007AFF）
- [x] 生成した1024x1024のPNGを `Assets.xcassets/AppIcon.appiconset/` に配置し、`Contents.json` を更新
- [x] DesignSystemのセマンティックカラーを適用した。D1、D4、D5で、物件価格、通勤バッジ、値上がりと値下がりの色を定数化した。

### Phase 13: ハイブリッド改善（データ取得の最適化、完了）
- [x] デフォルトURLをアプリにハードコード（初回のURL設定を不要にした）。現在の既定の取得元はSupabaseである。
- [x] ETagによる差分チェック（未変更なら全件ダウンロードをスキップ）。現在はカスタムURLのJSON経路だけが対象である。
- [x] GitHub Actionsの更新頻度を1日4回に増やした。時刻はJST 06:00、12:00、19:00、00:00である。現在のスケジュールはJST 9:00、15:00、18:00、20:00である（`scrape-listings.yml`）。
- [x] Settings画面改善（カスタムURLを「詳細設定」に折りたたみ、ステータス表示を追加）
- [x] フルリフレッシュ機能（ETagキャッシュをクリアして全件を再取得）

### Phase 14: バグ修正、UX改善、パフォーマンス最適化（完了）

#### Criticalバグ修正
- [x] 地図のいいねボタンの保存バグを修正（`modelContext.save()` の呼び出し漏れ）
- [x] `try!` のクラッシュリスクを修正（`do/catch` と `fatalError` に変更）
- [x] デフォルトURL利用時に更新ボタンが無効になるバグを修正
- [x] GitHub Actionsのcommitステップで件数カウントが誤るバグを修正

#### UX改善
- [x] 東京都地域危険度GeoJSONのデフォルトURLを設定（設定なしで表示できる）
- [x] プッシュ通知をタップすると中古タブへ自動遷移する
- [x] メモのFirestore書き込みにデバウンス（0.8秒）を入れ、キーストロークごとの送信を防ぐ。現在はメモをコメントに置き換え、書き込み先は `SupabaseAnnotationService` である。
- [x] エラーメッセージの表示を改善（ツールバーアイコンとアラートで全文表示）
- [x] 空状態のメッセージを「更新ボタンをタップして〜」に変更
- [x] FCMトークンのログを `#if DEBUG` で囲む

#### パフォーマンス最適化
- [x] ListingStore: `#Predicate` による `propertyType` フィルタ（全件フェッチから対象のみへ）
- [x] FirebaseSyncService: FirestoreのINクエリでバッチ取得するようにした。全ドキュメントの取得をやめ、対象のみを取得する。現在は `FirebaseSyncService` を削除済み。
- [x] ジオコーディング: TaskGroupによる2並列化（直列に比べて約2倍速）
- [x] ハザードマップオーバーレイ: 差分更新（描画のたびに全削除して再追加していたのを、変更時のみにした）

#### スクレイピングツール改善
- [x] HOME'Sスクレイパーに5xxエラーのリトライを追加（SUUMOと同等）
- [x] 全スクレイパーに429レートリミット処理を追加（`Retry-After` に対応）
- [x] `check_changes.py`: 価格以外の属性変更も検知（`listing_has_property_changes` を使用）
- [x] SUUMOとHOME'Sの並列スクレイピング（`ThreadPoolExecutor` で約2倍速）
- [x] FCMプッシュ通知の送信にリトライを追加（最大3回、指数バックオフ）
- [x] GitHub Actions: スクレイピング失敗時のSlack通知ステップを追加

---

## 未確定仕様

### Firestore同期の競合解決
- 当時の状態: Firestoreの値を常にローカルに上書きしていた（last-write-wins）。
- 当時の検討: 同時編集が起きた場合に、`updatedAt` でマージする。家族が少人数なので問題にならない想定だった。
- 現在は、いいねとコメントがSupabaseに移ったため、この項目はFirestoreには当てはまらない。Supabase側の競合解決は未検討である。

### Firestoreセキュリティルール（設定済み）
- テストモード（30日で期限切れ）から、認証済みユーザーだけがread/writeできるルールに変更済み。現行のルールはリポジトリの `firestore.rules` にある。

### リモートプッシュ通知（設定完了）
- FCMをGitHub Actionsから直接送信する。
- トピック `new_listings` を購読し、新着を検出するとプッシュする。
- APNs認証キー（.p8）はFirebase Consoleにアップロード済み。
- サービスアカウントのJSONは、GitHub Actionsの `FIREBASE_SERVICE_ACCOUNT` シークレットに設定済み。

### 自治体独自ハザード情報（設定完了）
- GSIの追加タイルレイヤー（内水浸水、浸水継続時間、家屋倒壊の氾濫流と河岸侵食）
- 東京都地域危険度（建物倒壊、火災、総合）のGeoJSONオーバーレイ
- GeoJSONの生成とコミット済み

---

## 実装済み機能一覧

- [x] 物件一覧表示（SwiftData）
- [x] 物件詳細表示
- [x] 外部ブラウザでSUUMOとHOME'Sを開く
- [x] データ同期（GitHub rawのJSONからSwiftDataへ）。現在の既定はSupabaseからの同期である。
- [x] 新着物件のローカル通知
- [x] BGAppRefreshTaskによるバックグラウンド自動取得
- [x] いいね機能
- [x] メモ機能（現在はコメント機能に置き換え）
- [x] お気に入りタブ（現在は「マイリスト」タブ）
- [x] ソート（追加日、価格、徒歩、広さ）
- [x] フィルタ（価格、間取り、駅（路線別）、徒歩、面積、所有権と定借）
- [x] 築年数表示
- [x] 追加日プロパティ（ソート用）
- [x] Firebase Firestoreによるいいねとメモの家族間共有（現在はSupabaseで共有）
- [x] iOS 26 Liquid GlassとiOS 17から25のMaterialフォールバック
- [x] HIGとOOUIに準拠したデザイン
- [x] 新築マンションスクレイパー（SUUMOとHOME'S。現在は削除済み）
- [x] 新築と中古のタブ分離（現在は新築を廃止）
- [x] 地図タブ（MKMapViewのUIViewRepresentable、ハザードマップタイルオーバーレイ、地域危険度、物件ピン）
- [x] ジオコーディング改善（CLGeocoderとSwiftDataキャッシュ）
- [x] 物件詳細画面の新築対応（引渡時期と種別の表示）
- [x] FCMリモートプッシュ通知（GitHub Actions、FCM HTTP v1 API、トピック送信）
- [x] GSIの追加ハザードレイヤー（内水浸水、浸水継続時間、家屋倒壊の氾濫流と河岸侵食）
- [x] 東京都地域危険度のGeoJSONオーバーレイ（建物倒壊、火災、総合、ランク1から5の色分け）
- [x] `convert_risk_geojson.py`（ShapefileをGeoJSONに変換するスクリプト。`scraping-tool/scripts/`）
- [x] `send_push.py`（FCM HTTP v1 APIのプッシュ通知スクリプト。`scraping-tool/scripts/`）
- [x] Google Sign-InのURLスキーム設定（`CFBundleURLTypes`）
- [x] `Assets.xcassets` と `AppIcon.appiconset` の作成
- [x] デフォルトURLのハードコード（初回セットアップを不要にした）
- [x] ETagによる差分チェック（条件付きGETで通信量を削減）
- [x] GitHub Actionsの更新頻度を1日4回にした
- [x] Settings画面のリニューアル（ステータス表示とカスタムURLの折りたたみ）
- [x] 地図のいいね保存バグ修正、`try!` の安全化、通知タップによる遷移、メモのデバウンス
- [x] Predicate最適化、Firestoreのバッチ取得、ジオコーディングの並列化、オーバーレイの差分更新
- [x] スクレイパーの5xxと429のリトライ、並列スクレイピング、変更検知の改善、失敗時のSlack通知

### Phase 15: 非機能改善とUX強化（完了）
- [x] N1: BackgroundRefreshのModelContextを `@MainActor` で作成（スレッド安全性）
- [x] N2: APNs環境をDebugはdevelopment、Releaseはproductionに自動で切り替える
- [x] N3: URLSessionにタイムアウトを設定（リクエスト30秒、リソース60秒）
- [x] N4: SwiftDataのsave失敗時のエラーハンドリングを強化
- [x] N5: Dynamic Type対応（ハードコードしたフォントサイズをText Styleに置換。現在は `.system(size:)` が73箇所残る）
- [x] N6: オフラインとタイムアウトのとき、日本語のエラーメッセージを表示する
- [x] F1: 新築価格フィルタの範囲交差判定を修正（`priceMan` から `priceMaxMan`）
- [x] F2: いいねやメモが付いた物件の自動削除を防ぐ
- [x] F3: 初回起動時にデータを自動取得する
- [x] F4: フォアグラウンドに戻ったとき、15分たっていれば自動更新する
- [x] F5: フィルタ結果がゼロ件のときの専用UI（リセットボタン付き）
- [x] F6: ソートの安定性を改善（同値のときは名前でタイブレーク）
- [x] F7: 地図タブにリフレッシュボタンを追加
- [x] F8: タブ選択を `@SceneStorage` で永続化
- [x] F9: 物件詳細画面にShareLink（共有）ボタンを追加
- [x] F10: REQUIREMENTS.mdの認証方式をGoogleサインインに更新
- [x] F11: 地図で、座標を取得できていない物件の数を表示する

### Phase 16: パフォーマンス最適化とバグ修正（完了）
- [x] P1: `fetchAndSync` の既存物件ルックアップを、O(n×m)からDictionaryによるO(n+m)に最適化
- [x] P2: 中古と新築のデータを `async let` で並列取得（ネットワークとデコードの部分）。現在は新築を廃止している。
- [x] P3: JSONデコードを `Task.detached` でバックグラウンド実行（UIのフリーズを防ぐ）
- [x] P4: DateFormatterをstaticで共有（一覧のスクロール時のアロケーションを削減）
- [x] P6: refreshの二重実行ガードを追加（`isRefreshing` のチェック）
- [x] P7: GeoJSONのデコードをバックグラウンド実行（地図タブのフリーズを防ぐ）
- [x] B1: スクレイパーの429リトライが全て失敗したときの `raise None` クラッシュを修正（全4ファイル）
- [x] B2: `update_listings.sh` で新築の変更チェックを追加（中古に変更がなくても新築の更新を反映する）。現在は新築を廃止している。
- [x] B3: BackgroundRefreshManagerの `Task.result` の例外処理を修正
- [x] B4: メモのデバウンスTaskを `onDisappear` でキャンセルし、最終状態を即座に同期
- [x] U1: 地図ピンの吹き出しボタンにVoiceOverのアクセシビリティラベルを追加

### Phase 18: メモからコメントへ（家族間共有と作成者表示、完了）
- [x] C1: `CommentData` 構造体を追加（id、text、authorName、authorId、createdAt）
- [x] C2: `Listing` に `commentsJSON: String?` プロパティを追加（SwiftDataの軽量マイグレーション。現在はスキーマバージョンを上げて再取得する方式）
- [x] C3: `FirebaseSyncService` をコメント対応に書き直した。現在は `FirebaseSyncService` を削除し、`SupabaseAnnotationService`（`AnnotationRouter` 経由）が同じ操作を行う。
  - `pushAnnotation` を `pushLikeState`（いいね専用）に分離
  - `addComment(for:text:modelContext:)` を新規追加（楽観的更新とFirestore mapへの書き込み）
  - `deleteComment(for:commentId:modelContext:)` を新規追加（自分のコメントだけ削除できる）
  - `pullAnnotations` でコメントmapをパースし、旧 `memo` から自動で移行する
- [x] C4: `ListingDetailView` のメモセクションをコメントセクションに差し替え
  - コメント一覧（アバター、作成者名、相対時間、削除ボタン）
  - テキスト入力と送信ボタン
  - 未ログインのときはログインを促すメッセージ
- [x] C5: `ListingListView` のメモプレビューをコメントプレビューに変更
- [x] C6: `MapTabView` と `ListingListView` の `pushAnnotation` を `pushLikeState` に変更
- [x] C7: 掲載終了した物件の削除保護に、コメントの有無のチェックを追加
- [x] C8: Firestoreのデータモデルとして `annotations/{docID}.comments` をmap形式で保存。`{ commentId: { text, authorName, authorId, createdAt } }` で同時書き込みを安全にする。現在、コメントの保存先はSupabaseである。

### Phase 18: 包括的な品質改善（完了）

#### デザイン
- [x] D1: DesignSystemにセマンティックカラー定数を追加（物件価格、通勤バッジ、値上がりと値下がり）
- [x] D2: Dynamic Type完全対応（`.system(size:)` をシステムフォントスタイルに置換。現在は `.system(size:)` が73箇所残る）
- [x] D4: 通勤バッジの色をDesignSystemの定数にした
- [x] D5: 価格の色をDesignSystemの定数にして一貫性を確保

#### UI/UX
- [x] U2: タブ間でフィルタ状態を共有（FilterStore、`@Observable`。現在は一覧と地図が独立した `FilterStore` を持ち、共有しない）
- [x] U3: コメントセクションを詳細画面の下部に移動（物件情報を先に表示）
- [x] U4: 地図に現在地ボタンを追加
- [x] U5: 空状態の案内を強化（「今すぐ更新」ボタンを追加）
- [x] U6: 更新時刻の表記を `HH:mm` 形式に改善
- [x] U8: お気に入りが0件のとき、チップバーを非表示にする

#### 機能
- [x] F1: テキスト検索（物件名のみ）
- [x] F2: 駅名フィルタ（FilterSheetにアコーディオンを追加）
- [x] F3: 物件比較機能（最大4件の横並び比較）
- [x] F5: お気に入りリストのCSVエクスポート

#### 実装とアーキテクチャ
- [x] I1: ListingモデルのMARKセクションを整理
- [x] I2: FlowLayoutを共有コンポーネントに抽出
- [x] I3: 地図の新築価格帯フィルタを範囲交差判定に修正（現在は新築を廃止）
- [x] I4: `try? modelContext.save()` を全箇所でエラーログ出力に改善
- [x] I5: FirebaseSyncServiceの責務をMARKセクションで明確化（現在は `FirebaseSyncService` を削除済み）

#### 非機能
- [x] C1: `NSCameraUsageDescription` と `NSPhotoLibraryUsageDescription` をInfo.plistに追加
- [x] C2: CommuteTimeServiceのencode nilガード
- [x] N2: GeocodingServiceのエラーハンドリングを改善
- [x] N3: オフライン動作を文書化
- [x] N4: パフォーマンス最適化を文書化
- [x] N5: アクセシビリティ対応を文書化
- [x] U4: `NSLocationWhenInUseUsageDescription` をInfo.plistに追加

#### スキップ
- D3: ダークモード対応（ユーザー指示により不要）
- F4: カラースキーム切り替え（D3に関連するため不要）
- N1: 単体テスト（当時は今後の課題として残した。現在は `RealEstateAppTests` にテストがある）
- I6: 駅名パースのテスト（N1に依存するため今後の課題）

---

## 手動セットアップ手順（完了）

- A. APNs認証キー（.p8）を作成し、Firebaseに登録
- B. Firebase Consoleの設定（AuthenticationとFirestore）
- C. Firestoreのセキュリティルール
- D. GitHub Actionsのシークレット（`FIREBASE_SERVICE_ACCOUNT`）
- F. 地域危険度GeoJSONの変換
- アプリアイコンの設定（Phase 12で対応済み）
  - カラースキームA（Blue #007AFF）を採用
  - 1024x1024のPNGを `Assets.xcassets/AppIcon.appiconset/` に配置済み
  - `DesignSystem.swift` にセマンティックカラーを適用済み
