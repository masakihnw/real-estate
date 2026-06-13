# リファクタリング提案書（実装前に承認が必要な項目）

`refactor-instructions.md` の Debt Map のうち「提案に留める」とした P1〜P8 をまとめる。
いずれも **このドキュメントの作成時点では未実装**。実施には公開API/スキーマ/外部連携/
互換性への影響判断（プロダクト判断）が必要なため、承認を得てから着手する。

各項目: 現状 → 提案 → リスク → 移行手順 → 検証方法。

---

## P1. Firebase 設定経路の撤去

### 調査で判明した実態（2026-06-13）
設定フローに**断絶**がある:

| 経路 | 書き込み先 | 読み取り |
|---|---|---|
| iOS `ScrapingConfigService`（設定画面） | Firestore `scraping_config/default` | Firestore |
| `push_scraping_config_to_firestore.py`（手動WF） | Firestore | — |
| パイプライン `main.py`（`supabase_config_loader`） | — | **Supabase** `scraping_config` |

- Supabase `scraping_config/default` は migration 039 のseed値で投入され、パイプラインが読む。
  更新は SQL（migration）でのみ可能。
- **Firestore → Supabase の同期は存在しない**。したがって iOS の設定編集（Firestore書き込み）は
  パイプライン（Supabase読み取り）に反映されていない。iOS 編集機能は実質的に
  パイプラインから切り離されている。

### Step 1（実施済み・本PR）
パイプラインと繋がっていない死蔵自動化を撤去:
- `push_scraping_config_to_firestore.py` を削除（参照は手動WFのみ）
- `.github/workflows/sync-firestore-scraping-config.yml` を削除
- iOS の Firestore 読み書きは現状維持（機能削除は別判断）

### Step 2（長期目標・要・明示ゴーサイン）
CLAUDE.md の方針（設定の単一ソースを Supabase に寄せる）に沿って完全移行:
1. iOS `ScrapingConfigService` を Supabase `scraping_config` の読み書きに作り替える。
2. Supabase 側に書き込み用 RLS ポリシー / RPC を追加（**migration → SQL をユーザーに適用依頼**）。
3. iOS の Firestore 経路（`ScrapingConfigService` の Firestore 依存）を削除。

### リスク（Step 2）
- iOS は Linux 環境でビルド/テスト不可 → CI（`ios-build.yml`）頼み。
- Supabase RLS 設計を誤ると設定テーブルが書き換え可能になる（認可境界）。
- そもそも iOS 設定編集機能を今後使うかの確認が前提（使わないなら機能ごと削除も選択肢）。

### 検証（Step 2）
- iOS: `ScrapingConfigView` の表示・編集が Supabase 経由で動作（CI + 手動）。
- 設定変更がパイプライン（`supabase_config_loader`）に反映されること。

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

## P4. 巨大ファイルの分割 — **report_utils 分割はスキップ推奨（2026-06-13）**

### report_utils.py 分割の再評価
`report_utils.py`（1043行）は **26ファイルが import** する中核モジュールで、最頻出は
`normalize_listing_name`(10) / `clean_listing_name`(8) / `identity_key_str`(7) など
dedup・名前キー系。既に `test_report_utils` + Phase 1 特性テストで手厚くカバー済みで
正常稼働中。分割すると26 importer の更新（または re-export シム追加）が必要で、便益は
ファイルサイズ縮小という見た目の改善が主。「見た目の綺麗さを目的にしない／証拠なく
全面書き換えしない」原則に照らし、**report_utils の分割は実施しない**。

iOS 巨大 View の分割（下記）は引き続き有効な提案として残す。

### iOS 巨大 View の分割（有効な提案）

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

## P5. スクレイパー基底クラスの導入 — **調査の結果スキップ推奨（2026-06-13）**

### 調査結果
共通化の価値が高い部分は既に抽出済み:
- `EmptyParseGuard`（連続0件停止判定）= Phase 3 / P6 で7スクレイパーに統一済み
- セッション生成・ジッター・フィルタ（`station_passengers_ok` 等）・`dump_debug_html`
  = `scraper_common.py` に集約済み

残る巡回ループは**本質的に分岐**しており、共通化に耐えない:

| スクレイパー | 区巡回 | fetch方式 |
|---|---|---|
| suumo / livable / rehouse | 区別(23区) | requests |
| nomucom | 単一連番 | requests |
| homes | 単一連番 | Playwright + WAF |
| athome | 区別 | requests + Playwright(詳細) |
| stepon | 単一連番 | Playwright(fetch_list_page_pw) |

3軸（区巡回有無 / requests vs Playwright / WAF・bot処理の差）で分岐し、
さらに metrics 記録条件・early-exit・finish_reason 分岐がサイト固有。
詳細 enrichment（athome/rehouse/nomucom）も、共通部分はキャッシュ入出力とループの
薄い定型のみで、キャッシュ無効化条件・パース・フィールドマージは全てサイト固有。

### 判断
基底クラス/共通ループ化は **過剰な抽象化**（指示書が負債として挙げる項目そのもの）になり、
サイトごとに調整されたフェイルセーフ（CLAUDE.md「パース0件は正常終端とbotブロックを区別」
「フェイルクローズ原則」）を壊すリスクが、得られる便益（行数削減＝見た目改善）を上回る。
よって **基底クラス化は実施しない**。共通化すべき核は既に抽出済みであり、残りは
accidental duplication ではなく genuine な domain variation と判断する。

### 将来の再検討トリガー
新規スクレイパーを追加する際に巡回ループの定型をコピペする場合は、その時点で
「区別 requests 型」など同型グループ内に限った薄いヘルパー抽出を検討する。

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
