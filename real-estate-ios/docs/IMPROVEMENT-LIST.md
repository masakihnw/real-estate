# 改善候補一覧

実装・デザイン・UI/UX・機能・非機能の観点から、改善できる箇所を整理した。

> 最終更新: 2026-02-11（Phase 19 包括的品質改善後）
> 2026-10-02 にコードと照合し、D2、N1、I5 の記述を更新した。

2026-06 の UI/UX 刷新（Phase 1〜5）に関わる残件は、リポジトリ直下の `docs/BACKLOG.md` を正本とする。本書は2026-02時点の改善候補の記録である。刷新後のデザイン、比較、フィルタの状態は BACKLOG.md と、リポジトリ直下の `docs/UIUX_REDESIGN_PROPOSAL.md` に従う。

---

## 1. デザイン

### D1. DesignSystem とカラースキーム: 対応済み
- `DesignSystem.swift` にアクセントカラーとセマンティックカラーの定数を定義済み。

### D2. Dynamic Type 完全対応: 一部対応済み
- `.system(size:)` をシステムフォントスタイル（`.caption`, `.footnote`, `.body` 等）へ置き換える作業を、2026-02に行った。
- 2026-10-02 時点で、`RealEstateApp` 配下に `.system(size:)` が73箇所ある（`grep -rn --include='*.swift' '\.system(size:' real-estate-ios/RealEstateApp`）。置き換えは完了していない。
- 新規コードでは `DS.Typography` を使い、`.system(size:)` を新たに書かない方針である（`docs/UIUX_REDESIGN_PROPOSAL.md` §4.1）。

### D3. ダークモード固定: スキップ
- ユーザー指示により、ライトモード固定のままにしている（`RealEstateAppApp.swift` の `.preferredColorScheme(.light)`）。

### D4. 通勤バッジの色: 対応済み
- `DesignSystem` に定数として切り出し済み。

### D5. 価格色の一貫性: 対応済み
- `DesignSystem.positiveColor` / `negativeColor` で統一済み。

---

## 2. UI/UX

### U1. 一覧行の情報密度: 検討中
- 現状のカード表示を維持する。将来、簡易表示と詳細表示の切り替えを検討する。

### U2. フィルタのタブ間共有: 対応済み
- `FilterStore`（`@Observable` シングルトン）で全タブが共有する。

### U3. コメントセクション配置: 対応済み
- 物件情報・通勤・ハザード・写真の後にコメントを配置した。

### U4. 現在地ボタン: 対応済み
- 地図のオーバーレイに現在地ボタンを追加した。

### U5. 空状態の案内: 対応済み
- 「今すぐ更新」ボタン付きの空状態表示と、フィルタ結果ゼロ件の専用UIを実装した。

### U6. 更新状態表示: 対応済み
- HH:mm 形式で表示する。

### U7. フィルタ結果プレビュー: 将来課題
- 条件を変えたときの件数表示は実装済み。差分表示は将来検討する。

### U8. お気に入り 0 件時のチップバー: 対応済み
- 0 件のときはチップバーを非表示にする。

---

## 3. 機能

### F1. 検索機能: 対応済み
- 物件名のインクリメンタル検索（`.searchable` モディファイア）。

### F2. 駅フィルタ: 対応済み
- フィルタシートに「駅名」アコーディオンを追加した。

### F3. 物件比較: 対応済み
- 最大4件を並べて比較する（`ComparisonView`）。

### F4. カラースキーム切り替え: スキップ
- D3 に関わるため不要（ユーザー指示）。

### F5. エクスポート: 対応済み
- お気に入り一覧の CSV エクスポート（`ShareLink`）。

---

## 4. 実装・アーキテクチャ

### I1. Listing モデル整理: 対応済み
- MARK セクションで整理した。

### I2. FlowLayout 重複: 対応済み
- `Design/FlowLayout.swift` に共通化した。

### I3. フィルタロジック・新築価格バグ: 対応済み
- 地図の新築価格帯フィルタを、範囲交差の判定に修正した。

### I4. try? save からエラーハンドリングへ: 対応済み
- 全箇所を `do/catch` とエラーログに改めた。

### I5. FirebaseSyncService 責務分離: 対象外
- `FirebaseSyncService.swift` は PR #10 で削除済み（リポジトリ直下の `docs/refactor-proposals.md`）。現在のアノテーション同期は `SupabaseAnnotationService` が行う。

### I6. 駅名パースのテスト: 将来課題（N1 依存）
- `RealEstateAppTests` に、`parsedStations` を対象にしたテストは無い（2026-10-02 のgrepで確認）。

---

## 5. 非機能

### N1. 単体テスト: 一部対応済み
- `RealEstateAppTests` に57ファイルのテストがある（2026-10-02 時点）。`ListingFilter`（`ListingFilterTests`）と `LoanCalculator`（`LoanAssumptionsTests`）のテストを含む。
- 残りの重要ロジックのテスト追加は、引き続き予定している。

### N2. エラーハンドリング一貫性: 大幅改善済み
- `fatalError` の削減、`try?` から `do/catch` への統一、日本語エラーメッセージの追加を行った。

### N3. オフライン挙動の明文化: 将来課題
- DB-STRATEGY.md に記載済み。UI への明示は将来検討する。

### N4. パフォーマンス監視: 将来課題
- 個別の調査結果は、リポジトリ直下の `.claude/ios-performance-investigation.md` にある。

### N5. アクセシビリティ網羅性: 一部対応済み
- 一覧行・地図ピン・比較画面に `accessibilityLabel` / `accessibilityHint` を追加した。
- ハザードバッジとフィルタチップの網羅は、VoiceOver テストのときに確認する予定である。

---

## 6. 優先度の目安（残課題のみ）

| 優先度 | 項目 | 理由 |
|--------|------|------|
| 中 | N1, I6 | テストを追加して品質を保証する |
| 低 | U1, U7, N3, N4, N5 | 将来の改善候補 |

---

## 7. 参照

- [REQUIREMENTS.md](REQUIREMENTS.md)
- [TODO.md](TODO.md)
- [DB-STRATEGY.md](DB-STRATEGY.md)
