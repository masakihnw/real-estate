# 物件アプリ DB設計方針

保守性、UX、動作の軽さを満たすための、DBの持ち方と同期方針を定める。

---

## 方針の要約

| 観点 | 方針 |
|------|------|
| 持ち方 | 端末側はSwiftDataのローカルDBに持つ。物件データの取得元は既定でSupabaseで、設定で「Supabase API」をオフにした場合だけ一覧JSONを使う。Notion連携は行わない。 |
| 同期 | 同一物件は `identityKey` でマッチして更新し、新規は挿入し、掲載終了した物件はローカルから削除する。Supabase経路は前回同期以降の差分を取得し、JSON経路は一覧全体で置き換える。 |
| パフォーマンス | 一覧は `@Query` で取得した結果を、メモリ上でソートとフィルタする。件数が数千までなら十分に速い。 |
| 保守 | `Listing` のストアドプロパティを変えたら `RealEstateAppApp.swift` の `currentSchemaVersion` を上げる。端末側のストアは削除され、次の同期で再取得する。 |

---

## 1. 保守

### 1.1 取得元の使い分け

- 既定のSupabaseモード: `SupabaseListingStore` がSupabaseのRPCから物件を取得する。`ListingStore.useSupabase` の既定値は `true` である。
- JSONモード: 設定のデータ取得で「Supabase API」をオフにする。「カスタム URL 設定」にURLを入れると、そのURLの一覧JSON（GitHub rawなど）から取得する。ETagによる差分チェックが使える。
- いいねとコメントは `SupabaseAnnotationService` がSupabaseのRPCで読み書きする。ユーザーの識別にはFirebase AuthのUIDを使う。
- 物件データの正はSupabaseである。アプリはそのスナップショットをローカルに持つ。
- Notionは使わない。元はNotionで行っていたDB機能をアプリに寄せている。

### 1.2 スキーマ変更

- `Listing` のストアドプロパティを追加、削除、変更したら、`currentSchemaVersion` を1つ上げる。
- 起動時に、保存済みのバージョンが `currentSchemaVersion` より小さければ、SwiftDataのストアファイルと画像のディスクキャッシュを削除する。その後、サーバーから再取得する。
- VersionedSchemaとSchemaMigrationPlanは使っていない。
- ユーザーデータ（いいね、コメントなど）は、同期の途中で `UserAnnotationStore` がUserDefaultsにバックアップする。再取得した物件へ `identityKey` で照合して復元する。

### 1.3 データの流れ

```
[Supabase]（既定）           → アプリがRPCで差分を取得 → SwiftDataに反映
[カスタムURLの一覧JSON]（任意） → アプリがGET（ETag付き）→ パース → SwiftDataに反映
```

スクレイピングとenrichはGitHub Actionsで実行され、結果がSupabaseに書き込まれる。アプリ側にバックエンドは不要である。

---

## 2. UX

### 2.1 ローカルファースト

- 一覧と詳細は常にローカルDBから表示する。ネットワークがなくても見られる。
- 更新はpull-to-refreshによる手動実行か、バックグラウンド更新（BGAppRefreshTask）で行う。取得結果でローカルDBを更新する。

### 2.2 更新状況の表示

- 最終更新日時を一覧と設定の両方で表示し、「いつ時点のデータか」を明示する。
- 更新中はプログレスを表示する。エラーはツールバーのアイコンとアラートで出し、アラートでは全文を確認できる。

### 2.3 新規物件の通知

- 更新で新規物件を検出したら、ローカル通知で「○件の新規物件が追加されました」と知らせる。
- リモートプッシュはFCMで送る。GitHub Actionsのスクレイピング後に `scraping-tool/scripts/send_push.py` がトピック `new_listings` へ送信する。

---

## 3. 動作の軽さ

### 3.1 一覧

- 一覧のセルは軽く保つ。サムネイルは `TrimmedAsyncImage` で表示する。
- ソートとフィルタは、`@Query`（`#Predicate` で中古に絞り込み済み）で取得した結果に対してメモリ上で行う。件数が数千程度なら問題にならない。
- それ以上に増えた場合は、`FetchDescriptor` の `sortBy` と `predicate` でDB側に寄せる。

### 3.2 検索

- 物件名の検索は、`@Query` で取得した結果に対してメモリ上で絞り込む。数千件までなら十分に速い。
- 件数が膨大になった場合は、`FetchDescriptor` に名前や住所のcontainsを指定して、DB側で絞り込む形に変える。

### 3.3 同期処理

- 同期はメインスレッドをブロックしない。`async` で実装し、UIは `isRefreshing` でローディングを表示する。
- 差分の計算（新規、更新、削除）は、1回のfetchと1回のループで完結させ、N+1や重い処理を避ける。既存物件の検索には `identityKey` をキーにしたDictionaryを使う。

### 3.4 ユニーク制約とインデックス

- SwiftDataでは `@Attribute(.unique)` やインデックスを付けられる。現状の同期は `identityKey` のDictionaryで重複を防いでいる。ユニーク制約を足すと、重複の防止と検索の安定性が上がる。

---

## 4. まとめ

- DB: 端末はSwiftData、取得元は既定でSupabase。Notionは使わない。
- 同期: 同一物件は更新、新規は挿入、掲載終了は削除する。
- 保守: スキーマを変えたら `currentSchemaVersion` を上げて再取得する。
- UX: ローカルファースト、最終更新の明示、新規物件のローカル通知とFCM。
- パフォーマンス: メモリ上のソートとフィルタ、軽いセル、非同期更新で動作を軽くする。

必要に応じて、`FetchDescriptor` の `predicate` と `sortBy`、SwiftDataのインデックスでチューニングする。
