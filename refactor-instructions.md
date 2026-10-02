# refactor-instructions.md

実装担当モデルへのリファクタリング指示書です。
このリポジトリの既存仕様を変えずに、技術的負債を減らし、今後変更しやすい状態にすることが目的です。
見た目を整えることは目的に含めません。証拠なく大きな削除や全面書き換えをしてはなりません。

## 実施状況

2026-06-12から2026-06-13にかけて、Phase 1からPhase 6を実施済みです。D1からD9とP1からP8それぞれの結果は §7 と §8 に記録しました。提案に留めた項目の判断は [docs/refactor-proposals.md](docs/refactor-proposals.md) に書いてあります。

§7のDebt Mapと§6のBaselineは着手前の調査結果と手順であり、現在の状態は§8に書いた完了記録に従います。新しくリファクタリングを始める場合は、この指示書を手順の見本として使い、根拠の行番号と件数を取り直してください。

---

## 1. Objective

1. 本番で毎日動いているスクレイピング、enrichment、Supabase同期のパイプラインと、iOSアプリの既存挙動を一切変えずに、次の5点を達成する。
   - 重複実装の共通化（スクレイパーのフェイルセーフパターン）
   - 未テストのコア処理（dedup、レポート差分、フィルタロジック）へのテスト追加
   - 参照されていないことが確認できたコードの削除（証拠つきのものだけ）
   - ログとエラーハンドリングの統一（printからloggerへ）
   - 巨大なViewからのロジック抽出（テストできるUtilitiesへ）
2. 大きな設計変更（Firebaseの完全撤退、巨大ファイルの全面分割）は実装せず、提案に留める。

---

## 2. Project Understanding

### 何をするプロダクトか

「10年住み替え前提でインデックス投資に勝つ」中古マンション購入を支援する個人向けプラットフォームです。

- scraping-tool/（Python 3.11）: SUUMO、HOME'S、athome、livable、stepon、rehouse、nomucom、マンションレビューの8スクレイパーが物件を取得し、3段階のdedupにかけ、enrichment（通勤、ハザード、e-Stat、reinfolib、住まいサーフィン、Claude AI分析）を経て、Supabaseへ同期する。結果はMarkdownレポートとSlack通知にも出力する。
- real-estate-ios/（SwiftUI、iOS 17+、SwiftData、XcodeGen）: 物件閲覧、スワイプ評価、ウォッチリスト、地図、ダッシュボードを提供する。データはSupabase RESTから2段階で取得する（`listings_feed_light` の次に `get_listing_detail`）。いいねとコメントはSupabase RPC `upsert_annotation` で保存する。認証、FCM、写真Storage、スクレイピングログ閲覧にはFirebaseを使う。
- supabase/migrations/: 3桁連番で053まである。025は歴史的に2ファイルが同じ番号を持つ。このファイルには触らない。
- 本番運用はGitHub Actions（`.github/workflows/`、13本）。`scrape-listings.yml`（1日4回）が先に動き、`enrich-and-report.yml` がworkflow_runで続く。後者は結果をmainにgit pushする。detect-delisted、enrich-sumai、backfill-homes-imagesなども同じディレクトリにある。

### 主要エントリーポイント

| 種別 | パス |
|---|---|
| パイプライン本体 | `scraping-tool/main.py`（スクレイパー実行、dedup、JSON出力） |
| CI実行スクリプト | `scraping-tool/scripts/run_scrape.sh` / `run_enrich.sh` / `run_finalize.sh` |
| Supabase同期 | `scraping-tool/supabase_sync.py` |
| レポート生成 | `scraping-tool/generate_report.py` |
| Slack通知 | `scraping-tool/slack_notify.py` / `send_pending_drafts.py` |
| iOS | `real-estate-ios/RealEstateApp/RealEstateAppApp.swift`（@main） |

### 設定の単一ソース（片側だけ変更すると他の箇所も動かなくなる）

- スクレイピング条件の正は `real-estate-ios/RealEstateApp/ScrapingConfigMetadata.json` です。iOSと `scraping-tool/config.py` のフォールバックの両方が参照するため、片側だけ変更してはならない。
- 買い手コンテキストは `scraping-tool/config/buyer_profile.json`、`config/purchase_strategy.md`、`config/prompts/<module>.md`（ai_scoring と investment_summary）で構成する。変更したら `generate_buyer_context.py --write` で再生成する。
- ランタイムの上書きはSupabaseの `scraping_config` テーブルで行い、読み込みは `supabase_config_loader.py` が担う。旧実装の `firestore_config_loader.py` は削除済み。
- `docs/SPECIFICATION.md` と `docs/BUYER_PROFILE.md` は自動生成する。テストが同期を検証しているため、ソースを変更したら再生成しないとCIが失敗する。

---

## 3. Behaviors To Preserve（変えてはならない既存挙動）

1. **GitHub Actionsパイプラインの成立**: `run_scrape.sh` / `run_enrich.sh` / `run_finalize.sh` のCLIインターフェース、環境変数名、成果物パス（`results/latest_raw.json` など）、workflow間のartifact受け渡し。
2. **dedupの判定結果**: `main.py` の3段階dedup（listing_key、fuzzy、building_key）と `claude_dedup.py` の出力が、同じ入力に対して変わらないこと。
3. **フェイルクローズ原則**: 取得失敗を「掲載終了」と誤判定して大量削除しない。delisting判定のロジック（`detect-delisted.yml` の経路、`041_get_delisted_since.sql`）の挙動を変えない。
4. **スクレイパーのレート制御**: `config.py` の `*_REQUEST_DELAY_SEC` を下回らない。リトライ回数とjitterを変更しない。
5. **Supabaseスキーマと保存済みデータ**: 適用済みmigration（001から053）のファイル名と内容は変更しない。修正は新番号（054以降）で行い、適用は `.claude/CLAUDE.md` の「Supabase マイグレーション」の手順に従う。
6. **iOSの2段階フェッチと差分同期**: `SupabaseListingStore` の `lastSyncTimestamp` に基づく増分同期と、SwiftDataスキーマ（現v22）。スキーマを変更するとマイグレーションが失敗するため、リファクタリングでは変更しない。
7. **iOSのFirebase依存機能**: 認証（Google Sign-In）、FCM、写真Storageは現役です。`ScrapingLogService` はFirestoreを読み取っている。Firebaseはレガシーですが、まだ使っている。
8. **`main.py` のstdout JSON出力**: `main.py` 末尾の `print(json.dumps(...))` は仕様であり、logger化の対象外。
9. **`results/` 配下のコミット対象ファイル**（GeoJSON、supply_trends.json など）の生成フォーマット。

---

## 4. Non-Negotiables（作業規律）

- 最初に `git status` を確認する。既存の未コミット変更があれば、自分の変更と混ぜない（別ブランチかstashで分離し、ユーザーに報告する）。
- 編集前に、§6のコマンドの出力をbaselineとして記録する。
- 変更は小さく戻しやすい単位でコミットする。1コミットにつき1つの関心事に絞る。
- 無関係な整形やついでのリファクタリングをしない。`ruff format` の一括適用も禁止。
- `git add .` と `git add -A` は禁止。パスを指定して個別にaddする。
- 次のファイルはコミットしない: `*_html_cache/`、`*.bak`、`*.backup.json`、`enriched-chuko-sumai/`、`real-estate-ios/build/`、`.venv/`、`.env`、`*.db-wal`、`*.db-shm`。
- 新しいキャッシュや中間ファイルを生成するコードを足したら、同じコミットで `.gitignore` に登録する。
- `old/` と `results/**/old/` に新規ファイルを作らない。
- Python: `print()` でなく `logger.get_logger` を使う。パース関数は純粋関数に切り出し、`tests/` に最低1つテストを書く。
- iOS: 新規Swiftファイルを追加したら `xcodegen generate` を実行する。ロジックはViewでなく `Utilities/` に置く。`DateFormatter` は `static let` と `en_US_POSIX` で共有する。Mac Catalyst向けのコードは追加しない。
- APIキーをハードコードしない。
- 正しさが不明な点に出会ったら、実装を止めて質問する（§5）。

---

## 5. Stop And Ask Conditions（実装を止めて質問する条件）

次のどれかに該当したら、作業を止め、現状と選択肢を提示して指示を仰ぐ。

1. Supabaseのテーブル、ビュー、RPC、保存済みデータ、iOSのSwiftDataスキーマに影響が及ぶ変更。
2. Firebase関連コードの削除（下の「未確定事項」A参照）。
3. GitHub Actionsのworkflowファイル、スケジュール、secretsの変更。
4. テストと実装が矛盾している箇所を見つけた場合。どちらが正しいかを自分で決めない。
5. dedup、delisting、通知のロジック変更が出力の差分を生むと分かった場合。
6. `ScrapingConfigMetadata.json`、`buyer_profile.json`、`purchase_strategy.md`、`prompts/*.md` の内容変更が必要になった場合（再生成が連鎖し、本番 `ai_prompts` の再分析コストが発生する）。
7. 削除候補のコードに、1箇所でも参照（import、workflow、シェルスクリプト、ドキュメントの運用手順）が見つかった場合。

### 未確定事項（2026-06-12 にユーザーが回答して解決済み。記録として残す）

- A. Firebaseレガシーの削除可否: `firestore_config_loader.py` はPR #10で削除済み。`push_scraping_config_to_firestore.py` はiOS `ScrapingConfigService` のFirestore読み取りが現役だったため、このときは残した。その後2026-06-13のP1で、このスクリプトと `ScrapingConfigService` を削除した（[docs/refactor-proposals.md](docs/refactor-proposals.md) のP1参照）。
- B. iOSのレガシーデータ経路: `FirebaseSyncService.swift` と `shinchikuListURL` はPR #10で削除済み。`ListingStore` のカスタムJSON URLフォールバックは開発用として残す。
- C. Mac Catalyst設定: PR #10で `SUPPORTS_MACCATALYST: NO` に変更済み。
- D. `scraping-tool/data/listings.db` のGit追跡: CI artifactの受け渡し（`scrape-listings.yml` と `enrich-and-report.yml`）に使っているため、意図的に追跡している。維持する。

---

## 6. Baseline Commands（編集前に必ず実行し、結果を記録する）

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

baselineで失敗するテストがあれば、修正せずに記録してユーザーに報告する。自分の変更による失敗と区別するためです。

---

## 7. Debt Map（根拠、リスク、着手可否）

ここに書いた根拠と行番号は着手前（2026-06-12）の調査結果です。

### 実装してよいもの（Phase 2から5で扱う）

| # | 負債 | 根拠 | なぜ負債か | リスク | 改善案 | 検証 |
|---|---|---|---|---|---|---|
| D1 | コアdedupが未テスト | `main.py`（407行）の `dedupe_listings()` / `_merge_images()` にテストなし | パイプラインの中核であり、回帰を検知できない | 低（テスト追加のみ） | 現挙動を固定する特性テストを `tests/test_main_dedup.py` に追加 | pytest |
| D2 | レポート差分検出が未テスト | `generate_report.py`、`check_changes.py` | 通知の正確性に直結する | 低 | 入出力フィクスチャで特性テストを追加 | pytest |
| D3 | EMPTY_PARSE_TOLERANCEの4重実装 | suumo:931,999 / athome:82,690 / homes:122,662 / livable:87,496。定数名もそろっていない | 同じパターンが4か所にあり、修正漏れの原因になる | 中（挙動が同一であることが必須） | `scraper_common.py` に `EmptyParseGuard` クラス（連続空回数のカウントと停止判定）を追加する。D1に相当するテストを先に書いてから、4スクレイパーを順に置換する。1スクレイパーにつき1コミット | 各scraperの既存テストと新規ガードのユニットテスト |
| D4 | print()とロガーの混在（非テストコードに約270箇所） | `price_predictor.py:532-536`、`sumai_surfin_enricher.py:931,951,2207`、`reinfolib_cache_builder.py` など | CIログの可観測性が下がる。CLAUDE.mdのルールにも違反する | 低 | loggerへ置換する。例外は `main.py` のstdout JSON出力とCLIツールのユーザー向け出力。判断に迷うものは残す | ruff、pytest、該当スクリプトのドライラン |
| D5 | iOS DateFormatterのルール違反 | `ScrapingLogService.swift:36-44`（computed propertyで毎回生成）、`Listing+MarkdownExport.swift:146-147`（ループ内で生成） | 和暦端末のバグが再発するおそれがあり、生成のたびにメモリも使う | 低 | `Utilities/DateFormatting.swift` に `static let` と `en_US_POSIX` で集約し、参照を置換する | xcodebuild test |
| D6 | ハザード助言ロジックがViewの中にある | `ListingDetailView.swift:2394-2409` `hazardBuyerTips()`、`:2495-2499` `extractRank()` | テストできない。CLAUDE.mdのルールにも違反する | 低 | `Utilities/HazardAdvisor.swift` へ純関数として抽出し、ユニットテストを追加する | xcodebuild test |
| D7 | フィルタロジックの重複 | `ListingListView.swift:40-52`（FilterCache）と `DashboardView.swift:602-628` に似たフィルタ処理がある | 二重に保守することになる | 中 | 両者の挙動に差があるかをテストで固定してから、共通Utilityへ抽出する。挙動に差があれば質問する（§5-4） | 新規ユニットテストとxcodebuild test |
| D8 | `ListingFilter.swift`（347行）が未テスト | テストファイル一覧に該当なし | フィルタはUXの基本機能 | 低 | 述語ごとの特性テストを追加する（実装は変更しない） | xcodebuild test |
| D9 | 例外の握りつぶしが広範（except Exceptionが約480箇所） | `slack_notify.py`（18）、`sumai_surfin_enricher.py`（13）など | 障害が記録されないまま見逃される | 中 | 一括変更は禁止。触ったファイルの範囲でだけ `logger.debug/warning` を追記する。例外を再送出に変える変更は、フェイルセーフ挙動が変わるため不可 | pytest |

### 提案に留めるもの（承認なしに実装してはならない）

| # | 負債 | 根拠 | 提案内容 |
|---|---|---|---|
| P1 | Firebaseレガシー2ファイル | `firestore_config_loader.py`（import 0件、[DEPRECATED]マーカーあり）、`push_scraping_config_to_firestore.py`（手動workflowから参照あり） | 未確定事項A。前者だけを先行して削除する案を提示してよい |
| P2 | iOSのFirebaseとSupabaseの二重化 | `FirebaseSyncService.swift`、`useSupabase` フラグ、カスタムJSON URLフォールバック | 未確定事項B。撤退ロードマップ案を文書で提案する |
| P3 | Mac Catalyst設定の残存 | `project.yml:6,23,148` | 未確定事項C |
| P4 | 巨大ファイルの本格分割 | `sumai_surfin_enricher.py`（2,348行）、`ListingDetailView.swift`（3,133行）、`ListingListView.swift`（1,975行）、`MapTabView.swift`（1,830行）、`slack_notify.py`（1,028行）、`report_utils.py`（969行） | 分割方針（責務の境界とファイル構成）を提案文書にまとめる。D6とD7の小規模な抽出はPhase 4で実施してよいが、ファイル全体の再構成は承認後に行う |
| P5 | スクレイパー基底クラスの導入 | 8スクレイパーがdataclass、ページループ、詳細enrichmentを各自で実装している（athome、rehouse、nomucomで各約200行が重複） | D3の完了後の次段階として設計案を提案する。一斉移行は禁止 |
| P6 | EMPTY_PARSE_TOLERANCE未適用のスクレイパーへの適用 | stepon、rehouse、nomucom、mansion_reviewに同じパターンがない。CLAUDE.mdは「必ず適用」と規定している | 適用すると停止挙動が変わる（既存挙動の変更）ため、D3の共通化後に、適用するかどうかを質問してから実施する |
| P7 | migration 025の番号衝突 | `025_buyer_preference_summary.sql` と `025_health_check_logs.sql` | 何もしない。適用済みmigrationのリネームは禁止。新規採番が既存の最大番号より後であることだけを確認する |
| P8 | Claude系enricherのテスト不足 | `claude_text_enricher.py` / `claude_dedup.py` / `claude_image_analyzer.py` にテストなし（`test_claude_client.py` はある） | プロンプト合成、キャッシュキー、confidence閾値の特性テスト案を提案する。プロンプト本文を変更すると本番の再分析が走るため、本文には触れない |

---

## 8. Implementation Phases（この順に進める。各フェーズ末に検証とコミットを行う）

### Phase 0: 現状確認
- `git status` とbaseline（§6）を実行し、結果を `refactor-report.md`（作業記録。コミットしない）に記録する。
- baselineで失敗があれば、停止して報告する。

### Phase 1: テストの追加（挙動変更ゼロ）。完了（2026-06-12）
- D1: `main.py` のdedup特性テストを `tests/test_main_dedup.py`（16件）に実装した。
- D2: `generate_report.py` と `check_changes.py` の特性テストを `tests/test_check_changes.py`（9件）と `tests/test_generate_report.py`（9件）に実装した。差分検出の中核である `compare_listings` は、既存の `test_report_utils.py` がカバー済みだった。そのため、exit codeの仕様とレポート整形に絞った。
- D8: `ListingFilter.swift` の述語テストを `RealEstateAppTests/ListingFilterTests.swift` に実装した。
- このフェーズでは本体コードを1行も変更しない。

### Phase 2: 安全に整理できるもの。完了（PR #16 マージ済み）
- D4: printからloggerへの置換を7モジュールで実施した。対象はsumai_surfin_enricher、mansion_review_scraper、commute_gmaps_enricher、reinfolib_enricher、sumai_surfin_browser、build_transaction_feed、upload_floor_plans。CLI出力、デモ出力、進捗の継ぎ足し表示は、除外ルールに従って残した。
- D5: DateFormatterの共有化として `Utilities/DateFormatting.swift` を新設し、ScrapingLogServiceとListing+MarkdownExportを置換した。

### Phase 3: 小さな責務分離（Python）。完了（PR #17 マージ済み）
- D3: `EmptyParseGuard` を `scraper_common.py` に実装した（ユニットテスト5件）。livable、suumo、athome、homesの順に4スクレイパーを移行した。停止挙動、ログ、metricsの記録条件は従来と同じで、各スクレイパーのテストが全件通ることで確認した。

### Phase 4: 小さな責務分離（iOS）。完了
- D6: `HazardAdvisor` を抽出しテストを追加した。ListingDetailViewの `hazardBuyerTips` と `extractRank` を純関数にした。
- D7: 不要になった。mainのUI刷新（PR #7）で `DashboardView.swift` が削除され、TodayViewに再編された。懸念していたフィルタの重複はなく、フィルタの正準実装は `ListingFilter.apply(to:)` に統一済みだった（ListingListView、MapTabView、Transaction系が共通で使い、Phase 1のD8でテスト済み）。

### Phase 5: 触った範囲のエラーハンドリング改善。対象なし
- D9: このブランチで触ったPythonファイルは、Phase 2と3で既にマージ済みだった。握りつぶしのexceptを新規に導入した箇所はなく、ログの追加が必要な未処理の箇所も見つからなかったため、スキップした。

### Phase 6: 提案書の作成（実装しない）。完了
- P1からP6とP8を `docs/refactor-proposals.md` にまとめた。各項目に、現状、案、リスク、移行手順、検証方法を1セクションずつ書いた。P7は対応不要のため、記録のみ。
- その後の結果は同書に記録している。P1はFirebase設定経路の撤去で完了、P3は解消済み、P5と、P4の `report_utils.py` 分割はスキップを推奨、P6はstepon、rehouse、nomucomへの適用で完了（mansion_reviewはページ巡回をしないため対象外）、P8は純粋なロジックへのテスト追加まで完了した（対象の範囲は同書のP8を参照）。

---

## 9. Verification Requirements

- 各フェーズの末尾で必ず実行する: `cd scraping-tool && ruff check . && python3 -m pytest tests/ -q`
- Swiftの変更を含むフェーズの末尾では、`xcodegen generate` と `xcodebuild test` を実行する。ローカルで実行できなければ、pushしたあとに `ios-build.yml` のCI結果を確認する。
- ドキュメント生成のソース（config.py、ScrapingConfigMetadata.json、buyer context系）に触れた場合だけ、§6の再生成コマンドを実行し、差分をコミットに含める。触れていなければ再生成しない。
- スクレイパーを変更したら、可能であれば小さなデータセットでドライランを行う（例: `python suumo_scraper.py` を1区1ページ相当に絞る既存オプションがあれば使う。なければテストだけでよい）。本番相当のフルスクレイプは、対象サイトへの負荷が大きいため禁止する。
- テスト数は減らさない。スキップやxfailを追加するときは、理由をコミットメッセージに書く。

## 10. Reporting Format

作業が完了したとき、または停止したときに、次の形式で報告する。

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

## 11. Out-of-scope Items（今回やらないこと）

- Firebase撤退の実施（P1、P2、P3）。
- Supabaseスキーマの変更と新規migrationの作成。
- GitHub Actions workflowの変更。
- `sumai_surfin_enricher.py` や `ListingDetailView.swift` など、巨大ファイルの全面分割（P4）。
- スクレイパー基底クラスへの一斉移行（P5）。
- EMPTY_PARSE_TOLERANCE未適用のスクレイパーへの新規適用（P6）。
- プロンプト（`config/prompts/*.md`、各enricherのSYSTEM_PROMPT）の内容変更。
- `ref/`（購入研究資料）、`design/`、`docs/10year-index-mansion-conditions-draft.md` への変更。
- 依存ライブラリのバージョン更新。
- パフォーマンスチューニング（計測なしの最適化は禁止）。
- migration 025の衝突を直すこと（P7。触らない）。
