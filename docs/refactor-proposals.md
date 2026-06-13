# リファクタリング提案書（実装前に承認が必要な項目）

`refactor-instructions.md` の Debt Map のうち「提案に留める」とした P1〜P8 をまとめる。
いずれも **このドキュメントの作成時点では未実装**。実施には公開API/スキーマ/外部連携/
互換性への影響判断（プロダクト判断）が必要なため、承認を得てから着手する。

各項目: 現状 → 提案 → リスク → 移行手順 → 検証方法。

---

## P1. Firebase 設定プッシュ経路の撤去

### 現状
- `firestore_config_loader.py` は PR #10 で削除済み（import 0件だった）。
- `push_scraping_config_to_firestore.py`（約70行）は **温存中**。手動 workflow
  `sync-firestore-scraping-config.yml`（`workflow_dispatch` のみ）から呼ばれ、
  `ScrapingConfigMetadata.json` を Firestore に書き込む。
- iOS `ScrapingConfigService` は Firestore からスクレイピング設定を **読み込む**（現役）。

### 提案
スクレイピング設定の正準は `ScrapingConfigMetadata.json` + Supabase `scraping_config`
（`supabase_config_loader.py`）に一本化済み。Firestore 経路は iOS 設定画面の読み取り専用途
のみ。撤去するなら以下を一括で行う:
1. iOS `ScrapingConfigService` を Supabase 読み取りに移行
2. `push_scraping_config_to_firestore.py` と `sync-firestore-scraping-config.yml` を削除

### リスク
- iOS 設定画面（`ScrapingConfigView`）の表示が壊れる。
- Firestore に依存する他機能（未調査）への波及。

### 移行手順
1. iOS の Supabase `scraping_config` 読み取りクライアントを実装（既存 `SupabaseClient` 流用）。
2. `ScrapingConfigService` を切り替え、フィーチャーフラグで段階移行。
3. 旧 Firestore 読み取りを削除 → スクリプト/workflow を削除。

### 検証
- iOS: `ScrapingConfigView` の表示・編集が Supabase 経由で動作すること（手動 + UIテスト）。
- 設定変更がスクレイピングパイプラインに反映されること（`supabase_config_loader` 経路）。

---

## P2. iOS の Firebase/Supabase 二重化の解消

### 現状
- PR #10 で `FirebaseSyncService.swift`（アノテーション同期）と `shinchikuListURL` は削除済み。
- 残る Firebase 依存: 認証（Google Sign-In）、FCM、写真 Storage、ScrapingConfig/Log 読み取り。
- `ListingStore` にカスタム JSON URL フォールバック経路が残置（開発用）。

### 提案
Firebase の段階的撤退ロードマップを策定する。優先度は低い（認証・FCM・Storage は
Firebase が妥当な選択肢で、撤退の必然性は薄い）。少なくとも以下を判断:
- 認証を Supabase Auth に移すか、Firebase Auth を維持するか（プロダクト判断）。
- 写真 Storage を R2/Supabase Storage に寄せるか（画像は既に R2 移行が進行中 — PR #11系）。

### リスク
- 認証移行はユーザーの再ログインを強制する可能性。
- 写真 Storage 移行は既存内見写真の移行が必要。

### 移行手順（要・別途詳細設計）
ドメインごとに独立して判断・実施。一括移行は禁止。

### 検証
ドメインごとに既存機能の回帰テスト。

---

## P3. （解消済み）Mac Catalyst 設定

PR #10 で `SUPPORTS_MACCATALYST: NO` に変更済み。**追加作業なし。**
記録のため項目として残す。

---

## P4. 巨大ファイルの分割

### 現状（行数は変動するため目安）
- Python: `sumai_surfin_enricher.py`（約2,300行）、`slack_notify.py`（約1,000行）、
  `report_utils.py`（約970行）。
- iOS: `ListingDetailView.swift`（約3,100行）、`ListingListView.swift`（約1,900行）、
  `MapTabView.swift`（約1,800行）、`Listing.swift`（約3,300行、モデルなので妥当）。

### 提案
責務境界での分割。ただし**全面再構成は承認後**。安全に切り出せる単位の例:
- `report_utils.py` → `report_format.py`（整形）+ `dedup_keys.py`（listing_key/building_key/
  fuzzy_match）。Phase 1 で dedup の特性テストを整備済みなので比較的安全。
- `ListingDetailView.swift` → セクション単位で子 View ファイルへ（hazard / market /
  sumai_surfin など）。D6 と同じ「純ロジックは Utilities、表示は子 View」方針を継続。
- `sumai_surfin_enricher.py` → ブラウザ自動化 / パース / enrichment 本体の3層。

### リスク
- 分割時の import 循環・可視性（private→internal）変更。
- iOS は `xcodegen generate` で新規ファイルが取り込まれる前提（CI で検証）。

### 移行手順
1ファイル=1PR。切り出す関数群に先にテストを足してから移動（characterization first）。

### 検証
- Python: `ruff` + pytest 全パス。
- iOS: `ios-build.yml`。

---

## P5. スクレイパー基底クラスの導入

### 現状
8スクレイパーが dataclass・ページループ・詳細 enrichment を各自実装。Phase 3 で
EMPTY_PARSE_TOLERANCE は `EmptyParseGuard` に共通化済み。athome/rehouse/nomucom の
詳細ページ enrichment（各約200行）に類似構造が残る。

### 提案
共通のページ巡回ループ（ward/region イテレーション、ページネーション、fetch→parse→
filter→empty guard→metrics）をテンプレートメソッド or 関数として抽出。各スクレイパーは
parse 関数とフィルタ条件のみを差分として渡す。**一斉移行は禁止**、D3 と同じく1スクレイパー
ずつ。

### リスク
- サイトごとに微妙に異なるエラー処理（WAF / HTTPステータス分岐 / debug HTML 保全条件）を
  共通化で握り潰すと、フェイルセーフ挙動が変わる。
- 各スクレイパーのゴールデンテストが守りになるが、巡回制御部はテストが薄い。

### 移行手順
まず巡回制御部の特性テストを各スクレイパーに追加 → 共通ループを抽出 → 1つずつ移行。

### 検証
各スクレイパーのテスト + 小データセットのドライラン（本番フルスクレイプ禁止）。

---

## P6. EMPTY_PARSE_TOLERANCE 未適用スクレイパーへの適用

### 現状
stepon / rehouse / nomucom / mansion_review は `EmptyParseGuard` パターン未適用。
CLAUDE.md は「必ず適用」と規定。

### 提案
`EmptyParseGuard` を4スクレイパーにも適用する。ただし**停止挙動が変わる**（現在は
0件即 break かもしれない＝適用すると2回許容に変わる）ため、現状の各スクレイパーの
終端判定ロジックを調査し、変更が妥当か individual に判断してから実施。

### リスク
- 停止タイミングが変わることで、取得件数・実行時間・サイト負荷が変動する。
- 「正常終端」と「botブロック」の区別ロジックが各サイトで異なる。

### 移行手順
1スクレイパーずつ。現状の終端判定をテストで固定 → ガード適用 → 件数差を小データで確認。

### 検証
各スクレイパーのテスト + ドライランでの取得件数比較。

---

## P7. （対応不要）migration 025 の番号衝突

`025_buyer_preference_summary.sql` と `025_health_check_logs.sql` が同番号で併存。
適用済み migration のリネームは破壊的なため **何もしない**。新規採番が046以降であることの
確認のみ（現在 047 まで存在）。記録のため項目として残す。

---

## P8. Claude 系 enricher のテスト不足

### 現状
`claude_text_enricher.py` / `claude_dedup.py` / `claude_image_analyzer.py` にテストなし
（`test_claude_client.py` はあり）。

### 提案
プロンプト本文を変更せずに、以下の純ロジックへ特性テストを追加:
- プロンプト合成・キャッシュキー生成（`claude_client` のキー生成と整合するか）。
- `claude_dedup` の confidence 閾値による採否判定。
- レスポンス JSON のパース・バリデーション（不正値の除外）。

**プロンプト本文（config/prompts/*.md・各 SYSTEM_PROMPT）は変更しない**
（本番 `ai_prompts` の再分析を誘発しコストが発生するため）。

### リスク
- Claude API を叩かないよう、レスポンスをモック化する必要がある。
- 既存の enrichment 結果と乖離するテストを書くと誤った固定になる。

### 移行手順
パース/判定関数を（必要なら）純関数として切り出し → モックレスポンスで特性テスト追加。

### 検証
`ruff` + pytest。API は叩かない（モックのみ）。
