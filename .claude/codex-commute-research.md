# Codex調査依頼 通勤時間取得の代替手段

> 現行の通勤時間更新は、`.claude/routines/routine_1_data_prep.md` のStep 3（`station_commute_times` マスタを参照する方式）で行っている。この方式ではAPIもWebFetchも使わない。本文書は、方式を決める前にCodexへ出した調査依頼の記録である。Yahoo路線情報を使う旧手順は [cowork-commute-yahoo-transit.md](./cowork-commute-yahoo-transit.md) にある。

## 背景

不動産物件検索アプリで、各物件の最寄り駅から2つのオフィスへの通勤時間を自動取得したい。

### 現状

- Yahoo路線情報のWebページをWebFetchでスクレイピングしていた。
- 実行環境が「Claude Desktop Routines」（Anthropicのリモートサーバー上で動作）に移った。
- リモート環境からYahoo Transitへのアクセスが HTTP 403 Forbidden でブロックされる。
- 利用できるツールは、WebFetch（URLからHTML/JSONを取得）、WebSearch（Web検索）、Supabase MCP（DB操作）である。
- リモート環境の制約により、Playwrightなどのブラウザ操作は使えない。

### 要件

- 入力 最寄り駅名（例 「石神井公園」「西大島」「勝どき」）
- 出力 2つの目的地への通勤時間、乗り換え回数、ルート概要
  - playground 実住所と最寄駅は環境変数 `COMMUTE_OFFICES_JSON` で管理する（コミットしない）。
  - m3career 実住所と最寄駅は環境変数 `COMMUTE_OFFICES_JSON` で管理する（コミットしない）。
- 朝の通勤時間帯（9:00到着を想定）の実所要時間が望ましい。
- 対象は東京23区と周辺（神奈川・埼玉・千葉の一部）の鉄道駅である。
- 月あたり約200駅のクエリ（新規物件の追加分）を見込む。

### 精度要件

- 乗り換え時間を含むドアtoドアの所要時間が望ましいが、駅to駅の所要時間でも足りる。
- 乗り換え回数が分かると望ましい。
- 誤差は±5分程度まで許容する。

## 調査してほしいこと

### 1. 日本の乗り換え案内API（有料を含む）

- Google Maps Directions API（Transitモード） 料金体系、日本の鉄道への対応状況、精度、レート制限
- NAVITIME API 法人向けAPIの有無、料金、WebFetchでアクセスできるか
- 駅すぱあとWebサービスAPI（ヴァル研究所） 料金、個人開発者向けプラン
- ジョルダンAPI 同上
- その他 RESAS API、国土交通省のオープンデータなどで使えるものがあるか

### 2. 無料または低コストの代替案

- Google Maps URLからWebFetch `https://www.google.com/maps/dir/...` のようなURLでルート情報を取得できるか（403にならないか）
- Apple Maps / MapKit APIでルート検索ができるか
- GTFS（General Transit Feed Specification）データ 日本の鉄道のGTFSデータが公開されているか。ローカルでルートを計算する方法が実現可能か
- OpenTripPlannerと日本のGTFS セルフホストの乗り換え案内を、Supabase Edge Functionで動かせるか

### 3. 静的なアプローチ（APIなし）

- 駅間所要時間マスターテーブル オフィスの最寄駅への所要時間を事前に計算してSupabaseのテーブルに持つ。更新頻度をどうするか
- 路線ネットワークグラフとダイクストラ法 駅間の接続と所要時間をグラフにして最短経路を計算する。データソースに何を使えるか
- 既存の駅間所要時間データセット KaggleやGitHubなどに、日本の鉄道駅間所要時間のデータセットがあるか

### 4. 実装上の制約との適合性

各手段について次を評価する。

- Claude Desktop RoutinesのWebFetchでアクセスできるか（403にならないか）
- APIキーが必要な場合、WebFetchのヘッダーに付けられるか、Supabase Edge Function経由で呼べるか
- 月額コストの目安（月約200クエリを想定）
- セットアップの手間

## 期待するアウトプット

上の項目を調査し、次の形式でまとめる。

| 手段 | 精度 | コスト/月 | 導入難易度 | WebFetch対応 | おすすめ度 |
|------|------|----------|-----------|-------------|-----------|

加えて、最もおすすめの手段について次を示す。

- 具体的なAPIエンドポイントまたはデータソース
- サンプルのリクエストとレスポンス（可能なら）
- 実装ステップの概要
