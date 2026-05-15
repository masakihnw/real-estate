# ルーティン③: ヘルスモニタリング

- **スケジュール**: 毎日 JST 5:00
- **MCP**: Supabase（必須）
- **所要時間目安**: 5-10分
- **前提**: ルーティン①（JST 2:00）②（JST 4:00）が完了済みであること

---

## 概要

データパイプラインの健全性を監視し、問題があれば `notification_drafts` 経由で Slack アラートを送信する。
GHA の `slack_notify.py` がボット名義で送信する（Routine は Slack MCP を使用しない）。

Supabase project_id: `dzhcumdmzskkvusynmyw`
全ての SQL は Supabase MCP の `execute_sql` で実行すること。

---

## Step 1: エンリッチメントカバレッジ

```sql
SELECT * FROM health_check_enrichment_coverage();
```

結果テーブル（field_name, total_active, non_null_count, coverage_pct）を確認。

**最低基準**:

| フィールド | 基準 |
|---|---|
| listing_score | 70% |
| ai_recommendation_score | 50% |
| commute_info | 60% |
| hazard_info | 50% |
| price_fairness_score | 50% |
| ai_listing_score | 40% |
| ai_price_fairness_score | 40% |
| extracted_features | 30% |
| image_categories | 30% |
| ss_lookup_status | 30% |

最低基準未満のフィールドがあれば「⚠️」としてレポートに記録。基準以上なら「✅」。

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

---

## Step 3: データ品質

```sql
SELECT * FROM health_check_data_quality();
```

結果チェック:
- `score_mismatch_ls_no_ai`: listing_score はあるが AI推薦スコアなし → Routine 2 の対象漏れの可能性
- `images_no_categories`: 画像あり + カテゴリなし → Routine 2 Step 2 の対象漏れ
- `duplicate_active`: 重複アクティブ → Routine 1 dedup の対象漏れ

---

## Step 4: アノマリ検出

```sql
SELECT * FROM health_check_anomaly_detection();
```

`is_alert = true` の項目を重点報告。

---

## Step 5: 通知ドラフト生成

全ステップの結果を統合し、Slack 向けメッセージを作成。

### アラートなし（全正常）の場合:

```sql
SELECT skip_notification_draft('slack', 'health_report');
```

### アラートありの場合:

メッセージ構成:
```
🔍 *パイプラインヘルスレポート*（{日付}）

■ カバレッジ（アクティブ {total_active} 件）
  ✅ listing_score: 97.4% (基準70%)
  ⚠️ ai_recommendation_score: 42.1% (基準50%)
  ...（基準未満のみ ⚠️、それ以外は ✅）

■ パイプライン鮮度
  新着24h: {n}件 | AI分析24h: {n}件
  ⚠️ AI未分析: {n}件（5件以上で警告）
  
■ データ品質
  ✅ 重複アクティブ: 0件
  ⚠️ スコア不整合: {n}件

■ アノマリ
  ✅ 異常なし
```

保存:
```sql
SELECT upsert_notification_draft(
  'slack',
  'health_report',
  '<整形済みメッセージ>',
  '{"alerts": ["ai_recommendation_score below threshold"], "alert_count": 1}'::jsonb
);
```

---

## 完了レポート

各チェックの結果サマリーを報告:
- カバレッジ: 全X項目中 Y項目が基準未満
- パイプライン鮮度: 新着X件、AI分析Y件、陳腐化Z件
- データ品質: 不整合X件
- アノマリ: X件検出
- 通知ドラフト: {status} で保存

---

## 共通ルール
- **サブエージェント委任禁止**: 全ステップの処理はメインエージェントのコンテキストで実行すること
- ヘルスチェックの失敗は他のチェックをブロックしない
- 全チェック完了後に1つのサマリー通知ドラフトを生成する
- 対象が0件のチェックも「0件」として報告する（スキップしない）
- 日本語で回答すること
