# refactor-instructions.md

実装担当モデルへのリファクタリング指示書。
このリポジトリの既存仕様を壊さず、技術的負債を減らし、今後変更しやすい状態にすることが目的である。
**見た目の綺麗さは目的ではない。証拠なく大きな削除や全面書き換えをしてはならない。**

---

## 1. Objective

1. 本番で毎日動いているスクレイピング→enrichment→Supabase同期パイプライン、およびiOSアプリの**既存挙動を一切変えずに**、以下を達成する:
   - 重複実装の共通化(スクレイパーのフェイルセーフパターン)
   - 未テストのコア処理(dedup、レポート差分、フィルタロジック)への安全網追加
   - 明確に死んでいるコードの削除(証拠つきのもののみ)
   - ログ/エラーハンドリングの統一(print → logger)
   - 巨大Viewからのロジック抽出(テスト可能なUtilitiesへ)
2. 大きな設計変更(Firebase完全撤退、巨大ファイルの全面分割)は**実装せず提案に留める**。

---

## 2. Project Understanding

### 何をするプロダクトか

「10年住み替え前提でインデックス投資に勝つ」中古マンション購入を支援する個人向けプラットフォーム。

- **scraping-tool/** (Python 3.11): SUUMO/HOME'S/athome/livable/stepon/rehouse/nomucom/マンションレビューの8スクレイパー → 3段階dedup → enrichment(通勤・ハザード・e-Stat・reinfolib・住まいサーフィン・Claude AI分析) → Supabase同期 → Markdownレポート/Slack通知。
- **real-estate-ios/** (SwiftUI, iOS 17+, SwiftData, XcodeGen): 物件閲覧・スワイプ評価・ウォッチリスト・地図・ダッシュボード。データはSupabase REST(2段階フェッチ: `listings_feed_light` → `get_listing_detail`)。いいね/コメントはSupabase RPC `upsert_annotation`。認証・FCM・写真Storage・スクレイピング設定/ログ閲覧はFirebase。
- **supabase/migrations/**: 3桁連番045まで(025は歴史的に2ファイル衝突。**触らない**)。
- **本番運用はGitHub Actions**(.github/workflows/、10本)。`scrape-listings.yml`(1日4回) → `enrich-and-report.yml`(workflow_run連鎖、結果をmainにgit push) → detect-delisted / enrich-sumai / backfill-homes-images など。

### 主要エントリーポイント

| 種別 | パス |
|---|---|
| パイプライン本体 | `scraping-tool/main.py`(スクレイパー実行→dedup→JSON出力) |
| CI実行スクリプト | `scraping-tool/scripts/run_scrape.sh` / `run_enrich.sh` / `run_finalize.sh` |
| Supabase同期 | `scraping-tool/supabase_sync.py` |
| レポート生成 | `scraping-tool/generate_report.py` |
| Slack通知 | `scraping-tool/slack_notify.py` / `send_pending_drafts.py` |
| iOS | `real-estate-ios/RealEstateApp/RealEstateAppApp.swift`(@main) |

### 設定の単一ソース(壊すと連鎖破損する)

- スクレイピング条件の正: `real-estate-ios/RealEstateApp/ScrapingConfigMetadata.json`(iOSと`scraping-tool/config.py`フォールバックの両方が参照。**片側だけ変更禁止**)。
- 買い手コンテキスト: `scraping-tool/config/buyer_profile.json` + `config/purchase_strategy.md` + `config/prompts/<module>.md`(ai_scoring / investment_summary)。変更時は `generate_buyer_context.py --write` で再生成必須。
- ランタイム上書き: Supabase `scraping_config` テーブル(`supabase_config_loader.py`が現行。`firestore_config_loader.py`は旧)。
- ドキュメント同期: `docs/SPECIFICATION.md` と `docs/BUYER_PROFILE.md` は自動生成。**テストが同期を検証している**ため、ソース変更後は再生成しないとCIが落ちる。

---

## 3. Behaviors To Preserve(絶対に壊さない既存挙動)

1. **GitHub Actionsパイプラインの成立**: `run_scrape.sh` / `run_enrich.sh` / `run_finalize.sh` のCLIインターフェース、環境変数名、成果物パス(`results/latest_raw.json` 等)、workflow間のartifact受け渡し。
2. **dedupの判定結果**: `main.py` の3段階dedup(listing_key → fuzzy → building_key)と `claude_dedup.py` の出力が、同一入力に対して変わらないこと。
3. **フェイルクローズ原則**: 取得失敗を「掲載終了」と誤判定して大量削除しない。delisting判定ロジック(`detect-delisted.yml` 経路、`041_get_delisted_since.sql`)の挙動を変えない。
4. **スクレイパーのレート制御**: `config.py` の `*_REQUEST_DELAY_SEC` を下回らない。リトライ回数・jitterを勝手に変えない。
5. **Supabaseスキーマと保存済みデータ**: 適用済みmigration(001〜045)のファイル名・内容は変更しない。修正は新番号(046〜)で行い、SQLは用意のみ(適用はユーザーが行う)。
6. **iOSの2段階フェッチと差分同期**: `SupabaseListingStore` の `lastSyncTimestamp` ベース増分同期、SwiftDataスキーマ(現v22)。スキーマ変更はマイグレーション破壊につながるため禁止。
7. **iOSのFirebase依存機能**: 認証(Google Sign-In)、FCM、写真Storage、`ScrapingConfigService` / `ScrapingLogService` のFirestore読み書きは現役。**Firebaseはレガシーだが死んでいない。**
8. **`main.py` のstdout JSON出力**(`main.py:403` 付近のprintは仕様。logger化対象外)。
9. **`results/` 配下のコミット対象ファイル**(report.md、GeoJSON、supply_trends.json等)の生成フォーマット。

---

## 4. Non-Negotiables(作業規律)

- 最初に `git status` を確認する。既存の未コミット変更があれば自分の変更と混ぜない(別ブランチ/stashで分離し、ユーザーに報告)。
- 編集前にbaseline検証結果(§6のコマンド出力)を記録する。
- 変更は小さく戻しやすい単位でコミットする。1コミット=1関心事。
- 無関係な整形・ついでのリファクタリングをしない。`ruff format` の一括適用等も禁止。
- `git add .` / `git add -A` 禁止。パス指定で個別にadd。
- 以下をコミットしない: `*_html_cache/`、`*.bak`、`*.backup.json`、`enriched-chuko-sumai/`、`real-estate-ios/build/`、`.venv/`、`.env`、`*.db-wal`、`*.db-shm`。
- 新しいキャッシュ/中間ファイルを生成するコードを足したら同一コミットで `.gitignore` に登録。
- `old/` や `results/**/old/` に新規ファイルを作らない。
- Python: `print()` でなく `logger.get_logger`。パース関数は純粋関数に切り出し `tests/` に最低1つテスト。
- iOS: 新規Swiftファイル追加後は `xcodegen generate`。ロジックはViewでなく `Utilities/` へ。`DateFormatter` は `static let` + `en_US_POSIX`。Mac Catalyst向けコードを**追加しない**。
- APIキーのハードコード禁止。
- 正しさが不明な点に遭遇したら、実装を止めて質問する(§5)。

---

## 5. Stop And Ask Conditions(実装を止めて質問する条件)

以下に該当したら**作業を止め、現状と選択肢を提示して指示を仰ぐ**:

1. Supabaseのテーブル/ビュー/RPC、保存済みデータ、iOS SwiftDataスキーマに影響が及ぶ変更。
2. Firebase関連コードの削除(下記「未確定事項」A参照)。
3. GitHub Actionsのworkflowファイル・スケジュール・secretsの変更。
4. テストと実装が矛盾している箇所を見つけた場合(どちらが正か勝手に決めない)。
5. dedup・delisting・通知のロジック変更が出力差分を生むことが判明した場合。
6. `ScrapingConfigMetadata.json`、`buyer_profile.json`、`purchase_strategy.md`、`prompts/*.md` の内容変更が必要になった場合(再生成連鎖+本番`ai_prompts`再分析コストが発生する)。
7. 削除候補コードに1箇所でも参照(import、workflow、シェルスクリプト、ドキュメントの運用手順)が見つかった場合。

### 未確定事項(ユーザー回答待ち。回答がない限り着手禁止)

- **A. Firebaseレガシーの削除可否**: `firestore_config_loader.py` は完全未参照だが、`push_scraping_config_to_firestore.py` は手動workflow `sync-firestore-scraping-config.yml` から呼ばれており、iOSの `ScrapingConfigService` はFirestoreを読む。削除はFirebase撤退の進度に依存する。→ **回答があるまで両ファイルとも削除しない。**
- **B. iOS `FirebaseSyncService.swift`(328行)と `ListingStore` のカスタムJSON URLフォールバック / `shinchikuListURL` の削除可否**: ランタイムフラグ・ユーザー設定に依存するため。→ **回答があるまで削除しない。**
- **C. `project.yml` のMac Catalyst設定(`macCatalyst: "17.0"`、`SUPPORTS_MACCATALYST: "YES"` ×2)を `NO` にしてよいか**: ドキュメントは「廃止済み」だが設定が残る。配布済みビルドへの影響判断が必要。→ **回答があるまで変更しない。**
- **D. `scraping-tool/data/listings.db`(2.7MB SQLite)のGit追跡は意図的か**: `db.py` のローカルフォールバックDB。→ **回答があるまで.gitignore追加/削除をしない。**

---

## 6. Baseline Commands(編集前に必ず実行し結果を記録)

```bash
# 状態確認
git status && git branch --show-current && git log --oneline -3

# Python lint + テスト(現状で全パスすることを確認)
cd scraping-tool && ruff check . && python3 -m pytest tests/ -q

# ドキュメント同期検証(ソース変更していない限り差分ゼロのはず)
python3 scripts/generate_scraping_conditions_doc.py --write-spec && git diff --stat docs/SPECIFICATION.md
cd scraping-tool && python3 scripts/generate_buyer_context.py --write && git diff --stat ../docs/BUYER_PROFILE.md

# iOS(macOS環境がある場合のみ。ない場合はその旨を記録し、Swift変更はCIのios-build.ymlで検証)
cd real-estate-ios && xcodegen generate
xcodebuild test -project RealEstateApp.xcodeproj -scheme RealEstateApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

baselineで失敗するテストがあれば、**修正せず記録してユーザーに報告**(自分の変更の失敗と区別するため)。

---

## 7. Debt Map(根拠・リスク・着手可否つき)

### 実装してよいもの(Phase 2〜5で扱う)

| # | 負債 | 根拠 | なぜ負債か | リスク | 改善案 | 検証 |
|---|---|---|---|---|---|---|
| D1 | コアdedupが未テスト | `main.py`(407行)の `dedupe_listings()` / `_merge_images()` にテストなし | パイプラインの心臓部。回 帰検知不能 | 低(テスト追加のみ) | 現挙動を固定する特性テストを `tests/test_main_dedup.py` に追加 | pytest |
| D2 | レポート差分検出が未テスト | `generate_report.py`、`check_changes.py` | 通知の正確性に直結 | 低 | 入出力フィクスチャで特性テスト追加 | pytest |
| D3 | EMPTY_PARSE_TOLERANCEの4重実装 | suumo:931,999 / athome:82,690 / homes:122,662 / livable:87,496。定数名すらバラバラ | 同一パターンの4実装。修正漏れ温床 | 中(挙動同一性が必須) | `scraper_common.py` に `EmptyParseGuard` クラス(連続空回数カウント+停止判定)を追加し、**D1相当のテストを先に書いてから**4スクレイパーを順次置換。1スクレイパー=1コミット | 各scraperの既存テスト+新規ガードのユニットテスト |
| D4 | print()がロガー混在(非テストコードに約270箇所) | `price_predictor.py:532-536`、`sumai_surfin_enricher.py:931,951,2207`、`reinfolib_cache_builder.py` 等 | CIログの可観測性低下。CLAUDE.mdルール違反 | 低 | logger置換。**例外**: `main.py` のstdout JSON出力、CLIツールのユーザー向け出力は対象外。判断に迷うものは残す | ruff + pytest + 該当スクリプトのドライラン |
| D5 | iOS DateFormatterルール違反 | `ScrapingLogService.swift:36-44`(computed propertyで毎回生成)、`Listing+MarkdownExport.swift:146-147`(ループ内生成) | 和暦端末バグの再発リスク+アロケーション圧 | 低 | `Utilities/DateFormatting.swift` に `static let` + `en_US_POSIX` で集約し参照を置換 | xcodebuild test |
| D6 | ハザード助言ロジックがViewに埋没 | `ListingDetailView.swift:2394-2409` `hazardBuyerTips()`、`:2495-2499` `extractRank()` | テスト不能。CLAUDE.mdルール違反 | 低 | `Utilities/HazardAdvisor.swift` へ純関数として抽出+ユニットテスト追加 | xcodebuild test |
| D7 | フィルタロジックの重複 | `ListingListView.swift:40-52`(FilterCache)と `DashboardView.swift:602-628` で類似フィルタ処理 | 二重保守 | 中 | まず両者の挙動差の有無をテストで固定→共通Utilityへ抽出。**挙動差があれば質問**(§5-4) | 新規ユニットテスト+xcodebuild test |
| D8 | `ListingFilter.swift`(347行)が未テスト | テストファイル一覧に該当なし | フィルタはUXの根幹 | 低 | 述語ごとの特性テスト追加(実装変更はしない) | xcodebuild test |
| D9 | 例外の握り潰しが広範(except Exceptionが約480箇所) | `slack_notify.py`(18)、`sumai_surfin_enricher.py`(13)等 | 障害の黙殺 | 中 | **一括変更禁止。** 触ったファイルの範囲内でのみ、`logger.debug/warning` の追記(例外を再送出に変える変更は不可=フェイルセーフ挙動が変わるため) | pytest |

### 提案に留めるもの(承認なしに実装禁止)

| # | 負債 | 根拠 | 提案内容 |
|---|---|---|---|
| P1 | Firebaseレガシー2ファイル | `firestore_config_loader.py`(import 0件、[DEPRECATED]マーカーあり)、`push_scraping_config_to_firestore.py`(手動workflowから参照あり) | 未確定事項A。前者のみ先行削除する案を提示可 |
| P2 | iOS Firebase/Supabase二重化 | `FirebaseSyncService.swift`、`useSupabase` フラグ、カスタムJSON URLフォールバック | 未確定事項B。撤退ロードマップ案を文書で提案 |
| P3 | Mac Catalyst設定残存 | `project.yml:6,23,148` | 未確定事項C |
| P4 | 巨大ファイルの本格分割 | `sumai_surfin_enricher.py`(2,348行)、`ListingDetailView.swift`(3,133行)、`ListingListView.swift`(1,975行)、`MapTabView.swift`(1,830行)、`slack_notify.py`(1,028行)、`report_utils.py`(969行) | 分割方針(責務境界・ファイル構成)を提案文書にまとめる。D6/D7の小規模抽出はPhase 4で実施可だが、ファイル全体の再構成は承認後 |
| P5 | スクレイパー基底クラス導入 | 8スクレイパーがdataclass/ページループ/詳細enrichmentを各自実装(athome/rehouse/nomucomで各約200行重複) | D3完了後の次段階として設計案を提案。一斉移行は禁止 |
| P6 | EMPTY_PARSE_TOLERANCE未適用スクレイパーへの適用 | stepon/rehouse/nomucom/mansion_reviewに同パターンなし。CLAUDE.mdは「必ず適用」と規定 | 適用すると停止挙動が変わる(=既存挙動の変更)ため、D3の共通化後に「適用するか」を質問してから実施 |
| P7 | migration 025の番号衝突 | `025_buyer_preference_summary.sql` / `025_health_check_logs.sql` | **何もしない。** 適用済みmigrationのリネームは禁止。新規採番が046以降であることの確認のみ |
| P8 | Claude系enricherのテスト不足 | `claude_text_enricher.py` / `claude_dedup.py` / `claude_image_analyzer.py` にテストなし(`test_claude_client.py` はあり) | プロンプト合成・キャッシュキー・confidence閾値の特性テスト案を提案。プロンプト本文の変更は本番再分析を誘発するため触らない |

---

## 8. Implementation Phases(この順で。各フェーズ末に検証+コミット)

### Phase 0: 現状確認
- `git status` / baseline(§6)を実行し、結果を `refactor-report.md`(作業記録、コミットしない)に記録。
- baseline失敗があれば停止して報告。

### Phase 1: 安全網の構築(挙動変更ゼロ)
- D1: `main.py` のdedup特性テスト。既存の `results/` サンプルや既存テストのフィクスチャ形式を流用し、現挙動をそのまま固定する。
- D2: `generate_report.py` / `check_changes.py` の差分検出特性テスト。
- D8: `ListingFilter.swift` の述語テスト(iOS環境がなければPythonフェーズ完了後にCI検証へ回す)。
- **このフェーズでは本体コードを1行も変更しない。**

### Phase 2: 明らかに安全な整理
- D4: print → logger 置換(対象外条件を厳守。1モジュール=1コミット)。
- D5: DateFormatter共有化。
- 検証: `ruff check .` + pytest全パス、iOSはxcodebuild test(またはCI)。

### Phase 3: 小さな責務分離(Python)
- D3: `EmptyParseGuard` を `scraper_common.py` に実装(先にユニットテスト)→ suumo → athome → homes → livable の順に1つずつ置換。各置換後にそのスクレイパーのテストを実行。
  - 置換は「同一入力で同一の停止判定になる」ことをテストで証明できた場合のみ。証明できなければそのスクレイパーはスキップして報告。

### Phase 4: 小さな責務分離(iOS)
- D6: `HazardAdvisor` 抽出+テスト。
- D7: フィルタ重複の挙動差をテストで確認 → 同一なら共通化、差があれば停止して質問。
- 各ステップで `xcodegen generate` を忘れない。

### Phase 5: 触った範囲のエラーハンドリング改善
- D9: Phase 2〜4で触ったファイルに限り、握り潰しexceptへのログ追記。

### Phase 6: 提案書の作成(実装しない)
- P1〜P6, P8 について、`docs/refactor-proposals.md` に各1セクション(現状・案・リスク・移行手順・検証方法)で提案をまとめる。

---

## 9. Verification Requirements

- 各フェーズ末に必ず実行: `cd scraping-tool && ruff check . && python3 -m pytest tests/ -q`
- Swift変更を含むフェーズ末: `xcodegen generate` + `xcodebuild test`(ローカル不可ならpush後に `ios-build.yml` のCI結果を確認)。
- ドキュメント生成ソース(config.py、ScrapingConfigMetadata.json、buyer context系)に触れた場合のみ、§6の再生成コマンドを実行し差分をコミットに含める。触れていない場合は再生成しない。
- スクレイパー変更後は、可能なら小データセットでのドライラン(例: `python suumo_scraper.py` を1区・1ページ相当に絞る既存オプションがあれば使用。なければテストのみで可。**本番相当のフルスクレイプ実行は禁止**=対象サイトへの負荷)。
- テスト数は減らさない。スキップ・xfailの追加は理由をコミットメッセージに明記。

## 10. Reporting Format

作業完了時(または停止時)に以下を報告する:

```
## 実施サマリ
- 完了したフェーズ / スキップしたフェーズと理由

## 変更一覧
- コミットごと: ハッシュ / 対象負債ID(D1等) / 変更ファイル

## 検証結果
- 最後に実行した全コマンドと結果(pytest件数、ruff、xcodebuild/CIリンク)
- baselineとの差分(新規テスト数、失敗ゼロの確認)

## 停止・質問事項
- §5に該当して止めた項目と、判断に必要な情報

## 提案書
- docs/refactor-proposals.md の目次
```

## 11. Out-of-scope Items(今回やらないこと)

- Firebase撤退の実施(P1/P2/P3)。
- Supabaseスキーマ変更・新規migration作成。
- GitHub Actions workflowの変更。
- `sumai_surfin_enricher.py` / `ListingDetailView.swift` 等、巨大ファイルの全面分割(P4)。
- スクレイパー基底クラスへの一斉移行(P5)。
- EMPTY_PARSE_TOLERANCE未適用スクレイパーへの新規適用(P6)。
- プロンプト(`config/prompts/*.md`、各enricherのSYSTEM_PROMPT)の内容変更。
- `ref/`(購入研究資料)、`design/`、`docs/10year-index-mansion-conditions-draft.md` への変更。
- 依存ライブラリのバージョン更新。
- パフォーマンスチューニング(計測なしの最適化禁止)。
- migration 025衝突の「修正」(P7: 触らない)。
