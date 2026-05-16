# ルーティン③: ヘルスモニタリング

- **スケジュール**: 毎日 JST 5:00
- **MCP**: Supabase（必須）
- **所要時間目安**: 5-10分
- **前提**: ルーティン①（JST 2:00）②（JST 4:00）が完了済みであること

---

## 概要

データパイプラインの健全性を監視し、結果を `health_check_logs` テーブルに保存する。
Routine 1/2 が `get_latest_health_check()` で参照し、問題があれば自律的に修正アクションを取る。
**Slack 通知は行わない**（DB 保存のみ）。

Supabase project_id: `dzhcumdmzskkvusynmyw`
全ての SQL は Supabase MCP の `execute_sql` で実行すること。

---

## Step 1: エンリッチメントカバレッジ

```sql
SELECT * FROM health_check_enrichment_coverage();
```

結果テーブル（field_name, total_active, non_null_count, coverage_pct）を確認。

**最低基準**:

| フィールド | 基準 | 備考 |
|---|---|---|
| listing_score | 70% | |
| ai_recommendation_score | 50% | |
| commute_info | 60% | |
| hazard_info | 35% | ハザードデータソース依存 |
| price_fairness_score | 20% | sumai surfin カバレッジ依存 |
| ai_listing_score | 10% | Routine 2 で漸増中（2週間後に見直し） |
| ai_price_fairness_score | 10% | Routine 2 で漸増中（2週間後に見直し） |
| extracted_features | 30% | |
| image_categories | 30% | |
| ss_lookup_status | 30% | |

最低基準未満のフィールドがあれば「⚠️」としてレポートに記録。基準以上なら「✅」。

結果を以下の構造で保持:
```json
{
  "listing_score": {"total": 100, "non_null": 95, "pct": 95.0, "threshold": 70, "ok": true},
  "ai_recommendation_score": {"total": 100, "non_null": 42, "pct": 42.0, "threshold": 50, "ok": false},
  ...
}
```

---

## Step 2: パイプライン鮮度

```sql
SELECT * FROM health_check_pipeline_freshness();
```

結果メトリクス:
- `new_listings_24h`: 0件の場合はスクレイピングパイプラインの異常を警告
- `ai_analyzed_24h`: `new_listings_24h` の50%未満ならAIパイプラインの遅延を警告
- `stale_ai_7d`: 10件以上なら再分析を推奨
- `never_ai_analyzed`: 5件以上なら警告
- `no_enrichment_48h`: 1件以上なら警告

結果を以下の構造で保持:
```json
{
  "new_listings_24h": {"value": 5, "detail": "...", "ok": true},
  "ai_analyzed_24h": {"value": 3, "detail": "...", "ok": true},
  "stale_ai_7d": {"value": 2, "detail": "...", "ok": true},
  "never_ai_analyzed": {"value": 0, "detail": "...", "ok": true},
  "no_enrichment_48h": {"value": 0, "detail": "...", "ok": true}
}
```

---

## Step 3: データ品質

```sql
SELECT * FROM health_check_data_quality();
```

結果チェック:
- `score_mismatch_ls_no_ai`: listing_score はあるが AI推薦スコアなし → Routine 2 の対象漏れの可能性
- `images_no_categories`: 画像あり + カテゴリなし → Routine 2 Step 2 の対象漏れ
- `duplicate_active`: 重複アクティブ → Routine 1 dedup の対象漏れ

結果を以下の構造で保持:
```json
{
  "score_mismatch_ls_no_ai": {"count": 3, "detail": "...", "ok": false},
  "images_no_categories": {"count": 0, "detail": "...", "ok": true},
  "duplicate_active": {"count": 0, "detail": "...", "ok": true}
}
```

---

## Step 4: アノマリ検出

```sql
SELECT * FROM health_check_anomaly_detection();
```

結果を以下の構造で保持:
```json
{
  "active_count_drop": {"value": 150, "threshold": 120, "is_alert": false, "detail": "..."},
  "score_contradiction": {"value": 0, "threshold": 0, "is_alert": false, "detail": "..."}
}
```

`is_alert = true` の項目を重点報告。

---

## Step 5: health_check_logs 保存

全ステップの結果を統合し、`health_check_logs` に保存する。

アラート一覧を集約:
- Step 1 で基準未満のフィールド名
- Step 2 で警告条件に該当したメトリクス
- Step 3 で count > 0 のチェック項目
- Step 4 で is_alert = true の項目

```sql
SELECT upsert_health_check_log(
  '<coverage JSON>'::jsonb,
  '<freshness JSON>'::jsonb,
  '<data_quality JSON>'::jsonb,
  '<anomalies JSON>'::jsonb,
  <alert_count>,
  '<alerts配列 JSON>'::jsonb
);
```

alerts 配列の例:
```json
[
  {"source": "coverage", "field": "ai_recommendation_score", "message": "42.0% < 基準50%"},
  {"source": "data_quality", "check": "score_mismatch_ls_no_ai", "message": "3件のスコア不整合"}
]
```

---

## 完了レポート

各チェックの結果サマリーを報告:
- カバレッジ: 全X項目中 Y項目が基準未満
- パイプライン鮮度: 新着X件、AI分析Y件、陳腐化Z件
- データ品質: 不整合X件
- アノマリ: X件検出
- health_check_logs: 保存完了（alert_count: X）

---

## 共通ルール
- **サブエージェント委任禁止**: 全ステップの処理はメインエージェントのコンテキストで実行すること
- ヘルスチェックの失敗は他のチェックをブロックしない
- 全チェック完了後に1つの health_check_logs レコードを保存する
- 対象が0件のチェックも「0件」として報告する（スキップしない）
- **Slack 通知は行わない** — 結果は DB 保存のみ。Routine 1/2 が参照して自律修正する。`upsert_notification_draft` や `notification_drafts` テーブルへの書き込みは**禁止**（書き込むと GHA が Slack に送信してしまうため）
- 日本語で回答すること
