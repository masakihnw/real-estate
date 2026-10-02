# リファクタリング提案書

[refactor-instructions.md](../refactor-instructions.md) のDebt Mapで「提案に留める」とした P1からP8をまとめます。
各項目は、承認を得てから着手する前提で書きました。公開API、スキーマ、外部連携、互換性に影響するため、プロダクトとしての判断が必要です。

各項目の構成は、現状、提案、リスク、移行手順、検証方法です。

## 各項目の現在の状態

| 項目 | 状態 | 記録日 |
|---|---|---|
| P1 Firebase設定経路の撤去 | 完了 | 2026-06-13 |
| P2 iOSのFirebaseとSupabaseの二重化 | 実装しない。設計メモのみ | 2026-06-13 |
| P3 Mac Catalyst設定 | 解消済み | 2026-06-12 |
| P4 巨大ファイルの分割 | `report_utils.py` の分割は実施しない。iOSの巨大Viewの分割は提案として残す | 2026-06-13 |
| P5 スクレイパー基底クラス | 実施しない | 2026-06-13 |
| P6 EMPTY_PARSE_TOLERANCEの適用 | 完了（stepon、rehouse、nomucom） | 2026-06-13 |
| P7 migration 025の番号衝突 | 対応不要 | 2026-06-13 |
| P8 Claude系enricherのテスト | 一部完了。追加済みの範囲は該当項に記載 | 2026-06-13 |

---

## P1. Firebase 設定経路の撤去

### 調査で判明した実態（2026-06-13）
設定フローが途中で途切れていました。

| 経路 | 書き込み先 | 読み取り |
|---|---|---|
| iOS `ScrapingConfigService`（設定画面） | Firestore `scraping_config/default` | Firestore |
| `push_scraping_config_to_firestore.py`（手動WF） | Firestore | なし |
| パイプライン `main.py`（`supabase_config_loader`） | なし | Supabase `scraping_config` |

- Supabase `scraping_config/default` には、migration 039 のseed値を投入してあります。パイプラインはこの値を読みます。更新できるのはSQL（migration）だけです。
- FirestoreからSupabaseへの同期はありません。iOSの設定編集はFirestoreへ書き込みます。パイプラインはSupabaseから読み取るため、この編集は反映されません。iOSの編集機能は、実質的にパイプラインから切り離されていました。

### Step 1（実施済み）
パイプラインと繋がっていない自動化を撤去しました。
- `push_scraping_config_to_firestore.py` を削除した（参照は手動WFだけだった）。
- `.github/workflows/sync-firestore-scraping-config.yml` を削除した。
- iOSのFirestore読み書きは、この時点では現状のまま残した（機能の削除は別に判断する）。

### Step 2（実施済み。2026-06-13に機能削除を選択）
ユーザーに確認した結果、iOSの設定編集機能は使っていないと分かった。設定はmigrationとSQLで更新している。そこで、Supabaseへ移行せずに機能を削除し、Firestoreの設定経路を完全に撤去した。
- `ScrapingConfigService.swift` を削除した（Firestore `scraping_config` の読み書き）。
- `ScrapingConfigView.swift` を削除した（開発者セクションの編集UI）。
- `SettingsView` から呼び出し（state、sheet、開発者ボタン）を除去した。
- バンドルの `ScrapingConfigMetadata.json` は残した。Pythonの `config.py` フォールバックと、`docs/SPECIFICATION.md` の生成が、これを正準ソースとして使うためです。

これでiOSのFirestore設定経路は完全に撤去されました。パイプライン設定の正準は、Supabaseの `scraping_config`（migrationで更新）に一本化されています。P1は完了です。

### 残ったFirebase依存（P2で扱う）
iOSには、Firestoreを読む `ScrapingLogService`（ログ閲覧）が残っています。認証、FCM、写真Storageに使うFirebase依存も残っています。これらはP2の対象です。

---

## P2. iOSのFirebaseとSupabaseの二重化の解消（設計メモのみ。2026-06-13に決定）

ユーザーの判断で、認証、FCM、写真StorageはFirebaseが適しているため、撤去しないことにしました。この項目は将来の参照用ロードマップとして残し、実装はしません。

### 現状のFirebase依存（PR #10とP1の完了後）
- PR #10で、`FirebaseSyncService.swift`（アノテーション同期）と `shinchikuListURL` を削除した。
- P1（PR #24）で、iOSのFirestore設定経路を撤去した。
- 残っているFirebase依存と評価は次のとおりです。

| ドメイン | 実装 | 評価 |
|---|---|---|
| 認証（Google Sign-In） | Firebase Auth | 維持する。移行すると全ユーザーに再ログインを強いることになり、得られる便益は小さい |
| FCM（プッシュ通知） | Firebase Messaging | 維持する。Firebaseが適した選択肢である |
| 写真Storage（内見写真） | Firebase Storage | 維持する。既存写真の移行コストが大きい。物件画像は別途R2への移行が進行中 |
| ログ閲覧（`ScrapingLogService`） | Firestore読み取り | 低から中のリスクでSupabaseへ移せる。ただし書き込み側の `upload_scraping_log.py` も変更が必要で、規模は中程度になる。必要になったときに実施する |

### 将来撤退する場合の原則
- ドメインごとに独立して判断し、実施する。一括移行は禁止。
- 認証の移行では、再ログインの導線と、移行期間中の二重認証を先に設計する。
- 写真はR2への移行（進行中）と整合させ、既存のFirebase Storage URLを移行するスクリプトを用意する。
- 各ドメインで既存機能の回帰テストを行う（iOSはCIの `ios-build.yml`）。

### 結論
現時点でP2の実装は不要です。Firebaseはレガシーですが、現役の依存として維持します。

---

## P3. Mac Catalyst設定（解消済み）

PR #10で `SUPPORTS_MACCATALYST: NO` に変更しました。追加の作業はありません。
記録のために項目を残します。

---

## P4. 巨大ファイルの分割

### report_utils.pyの分割は実施しない（2026-06-13）
`report_utils.py` は、dedupと名前キー系の関数が中心のモジュールです。2026-10-02時点で1,108行あり、29ファイルがimportしています。最も使われている関数は `normalize_listing_name`（10ファイル）、`clean_listing_name`（8ファイル）、`identity_key_str`（7ファイル）です。件数は2026-06-13時点です。`test_report_utils` とPhase 1の特性テストで十分にカバーされ、正常に稼働しています。

分割すると、importしている全ファイルを更新するか、re-exportの互換層を追加する必要があります。得られる便益は、ファイルサイズが小さくなるという見た目の改善が中心です。「見た目を整えることは目的としない」「証拠なく全面書き換えをしない」という方針に照らして、`report_utils.py` は分割しません。

iOSの巨大Viewの分割は、引き続き有効な提案として次に残します。

### iOSの巨大Viewの分割（有効な提案）

#### 現状（行数は変動するため目安）
- Python: `sumai_surfin_enricher.py`（約2,300行）、`slack_notify.py`（約1,300行）、`report_utils.py`（約1,100行）。
- iOS: `ListingDetailView.swift`（約3,100行）、`ListingListView.swift`（約2,000行）、`MapTabView.swift`（約2,000行）、`Listing.swift`（約3,400行。モデルなので現状のままでよい）。

#### 提案
責務の境界で分割する。全面的な再構成は承認後に行う。次の3つが、安全に切り出せる単位の例です。
- `report_utils.py` を `report_format.py` と `dedup_keys.py` に分ける。整形を `report_format.py` に置く。`dedup_keys.py` には listing_key、building_key、fuzzy_match を置く。Phase 1でdedupの特性テストを整備済みなので、比較的安全に切り出せる。上の再評価により、実施はしない。
- `ListingDetailView.swift` を、セクション単位（hazard、market、sumai_surfinなど）で子Viewのファイルに分ける。D6と同じく、純粋なロジックはUtilitiesに置き、表示は子Viewに置く。
- `sumai_surfin_enricher.py` を、ブラウザ自動化、パース、enrichment本体の3層に分ける。

#### リスク
- 分割によってimportが循環したり、可視性をprivateからinternalに変える必要が生じたりする。
- iOSでは、`xcodegen generate` で新規ファイルがプロジェクトに取り込まれることが前提になる（CIで検証する）。

#### 移行手順
1ファイルにつき1PRとします。切り出す関数群に先にテストを足してから移動します（特性テストを先に書く）。

#### 検証
- Python: `ruff` とpytestが全件通ること。
- iOS: `ios-build.yml` が通ること。

---

## P5. スクレイパー基底クラスの導入（調査の結果、実施しない。2026-06-13）

### 調査結果
共通化の価値が高い部分は、既に抽出済みでした。
- `EmptyParseGuard`（連続0件の停止判定）は、Phase 3とP6で7スクレイパーに統一した。
- セッション生成、ジッター、フィルタ（`station_passengers_ok` など）、`dump_debug_html` は、`scraper_common.py` に集約した。

残っている巡回ループは、サイトごとに分岐が異なり、共通化できません。

| スクレイパー | 区巡回 | fetch方式 |
|---|---|---|
| suumo / livable / rehouse | 区別（23区） | requests |
| nomucom | 単一連番 | requests |
| homes | 単一連番 | Playwright + WAF |
| athome | 区別 | requests + Playwright（詳細） |
| stepon | 単一連番 | Playwright（fetch_list_page_pw） |

分岐の軸は3つあります。区巡回の有無、requestsとPlaywrightのどちらを使うか、WAFとbot処理の違いです。さらに、metricsの記録条件、early-exit、finish_reasonの分岐がサイトごとに異なります。詳細enrichment（athome、rehouse、nomucom）も同様です。共通部分は、キャッシュの入出力とループの薄い定型しかありません。キャッシュを無効にする条件、パース、フィールドのマージは、すべてサイト固有です。

### 判断
基底クラスや共通ループにまとめると、過剰な抽象化になります。指示書が負債として挙げている項目そのものです。サイトごとに調整したフェイルセーフがあります。CLAUDE.mdの「パース0件は正常終端とbotブロックを区別」と「フェイルクローズ原則」が該当します。これを損なうリスクが、得られる便益（行数の削減）を上回ります。そのため、基底クラス化は実施しません。共通化すべき中核は既に抽出済みで、残りの重複は、サイトごとの本来の違いによるものだと判断しました。

### 将来の再検討の契機
新規スクレイパーを追加するときに、巡回ループの定型をコピーして済ませる場合は、その時点で検討します。検討するのは、区別requests型のような同型グループの中に限った、薄いヘルパーの抽出です。

---

## P6. EMPTY_PARSE_TOLERANCEの未適用スクレイパーへの適用（完了。2026-06-13）

### 実施前の状況
次の4サイトには `EmptyParseGuard` パターンが入っていませんでした。stepon、rehouse、nomucom、mansion_reviewです。CLAUDE.mdは、このパターンを必ず適用すると定めています。

### 実施した内容
- rehouseとnomucomを `EmptyParseGuard` に移行した。
- steponのパース0件で即breakする処理を、`EmptyParseGuard(2)` による連続2回での停止に変更した。この変更は、終端で最大1ページ余分に取得する挙動の変更を伴う。ユーザーの承認を得て実施した。
- mansion_reviewはページを巡回しない（サーキットブレーカー方式の）enricherなので、対象外とした。

### リスク（実施時に確認した点）
- 停止のタイミングが変わると、取得件数、実行時間、サイトへの負荷が変動する。
- 正常終端とbotブロックを区別するロジックは、サイトごとに異なる。

### 移行手順
1スクレイパーずつ移行しました。現状の終端判定をテストで固定し、ガードを適用し、小さなデータで件数の差を確認する手順です。

### 検証
各スクレイパーのテストと、ドライランでの取得件数の比較です。

---

## P7. migration 025の番号衝突（対応不要）

`025_buyer_preference_summary.sql` と `025_health_check_logs.sql` が同じ番号で併存しています。
適用済みmigrationのリネームは破壊的なので、何もしません。新規採番が既存の最大番号（2026-10-02時点で053）より後であることだけを確認します。記録のために項目を残します。

---

## P8. Claude系enricherのテスト不足（一部完了。2026-06-13）

### 実施前の状況
`claude_text_enricher.py`、`claude_dedup.py`、`claude_image_analyzer.py` にはテストがありませんでした（`test_claude_client.py` はありました）。

### 提案
プロンプト本文を変更せずに、次の純粋なロジックへ特性テストを追加します。
- プロンプトの合成とキャッシュキーの生成（`claude_client` のキー生成と整合するか）。
- `claude_dedup` の、confidence閾値による採否判定。
- レスポンスJSONのパースとバリデーション（不正な値の除外）。

プロンプト本文（`config/prompts/*.md` と各SYSTEM_PROMPT）は変更しません。変更すると、本番の `ai_prompts` の再分析が走り、コストが発生するためです。

### 実施した内容
2026-06-13のコミット62b08939で、API呼び出しを含まない純粋なロジックだけにテストを追加しました。
- `tests/test_claude_dedup.py`: `find_dedup_candidates` の候補絞り込み条件を検証している。条件は別ソース、面積差3㎡以内、価格差15%以内、同一建物である。`apply_dedup_results` のconfidence閾値による採否判定も検証している。
- `tests/test_claude_image_analyzer.py`: サムネイルの選定（最高スコア、junk除外）と、画像カテゴリの組み立て。
- `tests/test_claude_text_enricher.py`: 入力テキストの組み立てと文字数制限。

これらのファイルには、次を対象にしたテストが含まれていません。提案にあるプロンプトの合成、キャッシュキーの生成、レスポンスJSONのパースとバリデーションです。`test_claude_client.py` の範囲は今回確認していません。

### リスク
- Claude APIを呼ばないように、レスポンスをモックにする必要がある。
- 既存のenrichment結果と食い違うテストを書くと、誤った挙動を固定してしまう。

### 移行手順
パースと判定の関数を、必要に応じて純粋関数として切り出し、モックのレスポンスで特性テストを追加します。

### 検証
`ruff` とpytestを実行する。APIは呼ばず、モックだけで検証する。
