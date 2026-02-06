# 物件情報 iOS アプリ 要件定義

## 1. 概要

スクレイピング（SUUMO/HOME'S）で取得した物件を**1つの iOS アプリ**で閲覧する。アプリ内に物件 DB（SwiftData）を持ち、新規物件追加時に**アプリ内通知**で知らせる。Notion・Slack は本アプリでは連携しない（元々 Notion の DB 機能をアプリに寄せる想定）。HIG・OOUI・iOS 26 Liquid Glass に則った軽量で見やすいアプリを目指す。

---

## 2. 方針（確定）

| 項目 | 決定 |
|------|------|
| **データ取得** | 一覧 JSON の URL（GitHub raw 等）から取得。DB はアプリ内のみ。詳細は [DB-STRATEGY.md](DB-STRATEGY.md) 参照。 |
| **プッシュ通知** | **ローカル通知**を採用。BGAppRefreshTask でバックグラウンド自動取得し、新規を検出したらアプリから通知。リモートプッシュは Phase 2 で検討。 |
| **Notion** | 本アプリでは**連携しない**。Notion は別物として扱い、DB 機能はアプリに寄せる。 |
| **Slack** | 本アプリでは**連携しない**。アプリから通知できれば十分。 |
| **対象** | iOS 17 以降。iPad は対象外（iPhone のみ）。 |
| **ユーザー** | 自分用。家族だけインストールできる配布（TestFlight 等）を想定。 |
| **デザイン** | Human Interface Guidelines（HIG）・OOUI に厳密に則る。iOS 26 では Liquid Glass デザインシステムに対応し、iOS 17–25 では既存のシステムスタイルにフォールバック。 |
| **共有** | いいね・メモは **Firebase Firestore** で家族間共有。匿名認証。[セットアップ手順](FIREBASE-SETUP.md) 参照。 |

---

## 3. 機能要件

### 3.1 必須（実装済み）

- **物件一覧**: アプリ内 DB に保存された物件を一覧表示。
- **ソート**: 追加日（新しい順）、価格（安い順/高い順）、徒歩（近い順）、広さ（広い順）。
- **フィルタ**: 価格（範囲）、間取り（複数選択）、駅（路線別・複数選択）、駅徒歩（分以内）、専有面積（㎡以上）、権利形態（所有権/定期借地チェックボックス）。
- **物件詳細**: 1件タップで詳細表示（名前・住所・価格・間取り・専有面積・築年・駅徒歩・総戸数・権利形態・詳細 URL など）。外部ブラウザで SUUMO/HOME'S 詳細を開く。
- **いいね**: 各物件をいいね/解除。一覧・詳細どちらからも操作可能。
- **メモ**: 各物件にテキストメモを付与・編集。
- **お気に入りタブ**: いいね済みの物件だけを表示する専用タブ。
- **新規物件のプッシュ通知**: 新規追加があったときにローカル通知で知らせる。
- **バックグラウンド自動取得**: BGAppRefreshTask で定期的に JSON を取得し、新着検出→通知。
- **データの同期**: 手動（更新ボタン/pull-to-refresh）で「最新の物件リスト」を取得し、ローカル DB を更新。
- **いいね・メモの家族間共有**: Firebase Firestore で同期。

### 3.2 一覧に表示する情報

- 物件名、価格、間取り、専有面積、駅徒歩
- 築年数、階数/階建て、所有権/定借、総戸数
- 路線・駅名
- メモ（あれば1行プレビュー）
- いいねアイコン

### 3.3 あるとよい（未実装）

- 地図表示（既存の map_viewer のようなピン表示）。
- カラースキームのカスタマイズ（3案検討中、[プレビュー](../color-preview/index.html)）。
- リモートプッシュ通知（Phase 2）。

---

## 4. 非機能要件

- **軽い**: 起動が速く、一覧スクロールがスムーズ。
- **見やすい**: 情報密度を抑え、フォント・余白・階層を整理した UI。
- **オフライン**: 一度取得した一覧はオフラインでも閲覧可能（詳細 URL はオンライン時のみ開く）。

---

## 5. データ

- 物件 1 件の項目は既存 `scraping-tool/results/latest.json` に準拠する。
  - `name`, `url`, `address`, `price_man`, `area_m2`, `layout`, `built_year`, `station_line`, `walk_min`, `floor_position`, `floor_total`, `total_units`, `ownership`, `source`, `list_ward_roman` など。
- 新規判定は `identity_key` ベース。
- ユーザーデータ（`isLiked`, `memo`, `addedAt`）はローカル SwiftData + Firebase Firestore で管理。同期時に JSON 由来の値で上書きしない。

---

## 6. 想定アーキテクチャ

- **アプリ**: SwiftUI、SwiftData でローカル永続化、一覧・詳細・お気に入り・設定。HIG・OOUI・Liquid Glass（iOS 26）／Material フォールバック（iOS 17–25）。
- **データ同期**: 設定で保存した一覧 JSON の URL から取得し、SwiftData を更新。同一物件は `identityKey` でマッチして更新、新規は挿入、一覧から消えたものはローカルから削除。詳細は [DB-STRATEGY.md](DB-STRATEGY.md)。
- **通知**: BGAppRefreshTask でバックグラウンド自動取得（約30分間隔、OS判断）。新規検出でローカル通知。
- **共有**: Firebase Firestore（匿名認証）。いいね・メモを `annotations` コレクションに保存。push（変更即時）/ pull（起動時・更新時）。

---

## 7. ドキュメント一覧

| ファイル | 内容 |
|---------|------|
| [REQUIREMENTS.md](REQUIREMENTS.md) | 本ファイル。要件定義。 |
| [DB-STRATEGY.md](DB-STRATEGY.md) | ローカル DB（SwiftData）の設計と同期戦略。 |
| [DESIGN.md](DESIGN.md) | HIG・OOUI・Liquid Glass のデザイン指針。 |
| [FIREBASE-SETUP.md](FIREBASE-SETUP.md) | Firebase プロジェクトのセットアップ手順。 |
| [TODO.md](TODO.md) | 未確定事項・次回作業の TODO。 |

---

## 8. 用語

- **listing**: 物件 1 件のデータ。
- **identity_key**: 名前・間取り・専有面積・住所・築年・路線・徒歩で一意化するキー（価格は含めない）。
- **新規**: 前回取得リストに identity_key が存在しなかった物件。
- **annotation**: いいね・メモのユーザーデータ。Firebase Firestore で家族間共有。
