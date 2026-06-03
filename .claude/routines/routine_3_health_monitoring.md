# ルーティン③: ヘルスモニタリング

- **スケジュール**: 毎日 JST 6:30（1回/日）
- **MCP**: Supabase（必須）
- **所要時間目安**: 5-10分
- **前提**: ルーティン①（JST 3:00）②（JST 5:00）が完了済みであること

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
| suumo_images | 60% | 物件写真の取得率 |
| floor_plan_images | 50% | 間取り図の取得率 |

最低基準未満のフィールドがあれば「⚠️」としてレポートに記録。基準以上なら「✅」。

`health_check_enrichment_coverage()` に `suumo_images` / `floor_plan_images` が含まれない場合、以下のカスタムクエリで補完:

```sql
SELECT
  'suumo_images' AS field_name,
  COUNT(*) AS total_active,
  COUNT(*) FILTER (WHERE e.suumo_images IS NOT NULL AND jsonb_array_length(e.suumo_images) > 0) AS non_null_count,
  ROUND(100.0 * COUNT(*) FILTER (WHERE e.suumo_images IS NOT NULL AND jsonb_array_length(e.suumo_images) > 0) / NULLIF(COUNT(*), 0), 1) AS coverage_pct
FROM listings l
LEFT JOIN enrichments e ON e.listing_id = l.id
WHERE l.is_active = true
UNION ALL
SELECT
  'floor_plan_images',
  COUNT(*),
  COUNT(*) FILTER (WHERE e.floor_plan_images IS NOT NULL AND jsonb_array_length(e.floor_plan_images) > 0),
  ROUND(100.0 * COUNT(*) FILTER (WHERE e.floor_plan_images IS NOT NULL AND jsonb_array_length(e.floor_plan_images) > 0) / NULLIF(COUNT(*), 0), 1)
FROM listings l
LEFT JOIN enrichments e ON e.listing_id = l.id
WHERE l.is_active = true;
```

さらに **homes 物件固有の画像取得率** も確認:

```sql
SELECT
  COUNT(*) AS homes_total,
  COUNT(*) FILTER (WHERE e.suumo_images IS NOT NULL AND jsonb_array_length(e.suumo_images) > 0) AS homes_with_images,
  ROUND(100.0 * COUNT(*) FILTER (WHERE e.suumo_images IS NOT NULL AND jsonb_array_length(e.suumo_images) > 0) / NULLIF(COUNT(*), 0), 1) AS homes_image_pct
FROM listings l
JOIN listing_sources ls ON l.id = ls.listing_id AND ls.is_active AND ls.source = 'homes'
LEFT JOIN enrichments e ON e.listing_id = l.id
WHERE l.is_active = true;
```

homes 画像取得率が 30% 未満の場合は「⚠️」として記録し、Step 6b の `homes_images_backlog_large` issue として検知する。

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

## Step 3.5: AI品質スイープ（セーフティネット）

ルーティン①で漏れた品質問題を検出するセーフティネット。
修正は行わず、検出のみ。問題があれば `pipeline_issues` に登録し、次回ルーティン①で修正される。

1. 以下のクエリで「怪しい」物件を最大20件取得:
```sql
SELECT l.id, l.name, l.normalized_name, l.address, l.layout,
       l.area_m2, l.floor_position, l.built_year,
       ls.source, ls.price_man
FROM listings l
JOIN listing_sources ls ON l.id = ls.listing_id AND ls.is_active
WHERE l.is_active = true
AND (
  -- 名前にプロモーション文言が残っている可能性
  l.name ~ '[×【】◆★☆]'
  -- normalized_name にダッシュバリアントあり（英数字隣接のカタカナ長音）
  OR l.normalized_name ~ '[ー–—](?=[A-Za-z0-9])'
  OR l.normalized_name ~ '(?<=[A-Za-z0-9])[ー–—]'
  -- normalized_name が短すぎる/長すぎる
  OR LENGTH(l.normalized_name) <= 3
  OR LENGTH(l.normalized_name) >= 40
  -- 三点リーダーや省略記号が残っている
  OR l.normalized_name ~ '[…]'
  OR l.normalized_name ~ '\.{2,}$'
)
ORDER BY l.created_at DESC
LIMIT 20;
```

1b. 名前の表記揺れ重複を検出（住所+築年は一致するが normalized_name が異なるペア）:
```sql
SELECT l1.id AS id_a, l2.id AS id_b,
       l1.normalized_name AS norm_a, l2.normalized_name AS norm_b,
       l1.address AS addr_a, l2.address AS addr_b,
       l1.built_year, l1.area_m2 AS area_a, l2.area_m2 AS area_b
FROM listings l1
JOIN listings l2
  ON l1.id < l2.id
  AND l1.is_active AND l2.is_active
  AND l1.built_year = l2.built_year
  AND l1.normalized_name != l2.normalized_name
  AND SUBSTRING(l1.address FROM '.+?[区市].+?\d+') = SUBSTRING(l2.address FROM '.+?[区市].+?\d+')
  AND LENGTH(SUBSTRING(l1.address FROM '.+?[区市].+?\d+')) > 3
  AND LENGTH(l1.normalized_name) > 3
  AND LENGTH(l2.normalized_name) > 3
LIMIT 10;
```

→ 検出されたペアは `fuzzy_dedup_missed_{id_a}_{id_b}` として `pipeline_issues` に登録。
  ルーティン① Step 0.7 で AI 判定・修正される。

2. 取得した物件についてAI判定:
   a. **物件名品質**: `name` にプロモーション文言が混入していないか？
   b. **表記揺れ重複**: 同一住所・同一面積の別名物件が存在しないか？（1b の結果も参照）
   c. **異常データ**: normalized_name が明らかに物件名でないもの
   d. **省略記号残存**: 三点リーダー等が normalized_name に残っていないか？

3. 問題発見時は `pipeline_issues` に登録:
   ```sql
   SELECT upsert_pipeline_issue(
     '<issue_key>',
     '<severity>',
     'data_quality',
     '<title>',
     '<description>',
     '<metadata>'::jsonb,
     '<suggested_fix>',
     'auto_fixable'
   );
   ```

   issue_key の命名規則:
   - 表記揺れ重複: `fuzzy_dedup_missed_{id_a}_{id_b}`
   - プロモーション文言: `promotional_name_{id}`

結果を以下の構造で保持:
```json
{
  "checked_count": 5,
  "issues_found": 2,
  "issues": [
    {"type": "promotional_name", "listing_id": 123, "detail": "..."},
    {"type": "fuzzy_dedup_missed", "listing_ids": [456, 789], "detail": "..."}
  ]
}
```

対象が0件なら「品質問題なし」と記録してスキップ。

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

**注意**: `active_count_drop` がアラートになった場合、意図的な一括非アクティブ化（例: 新築物件の廃止、条件変更による除外）が原因でないか確認すること。直近のルーティン①実行ログや `listing_events` テーブルで大量の `deactivated` イベントがあれば false positive として扱い、`pipeline_issues` には登録しない。

---

## Step 5: health_check_logs 保存

全ステップの結果を統合し、`health_check_logs` に保存する。

アラート一覧を集約:
- Step 1 で基準未満のフィールド名
- Step 2 で警告条件に該当したメトリクス
- Step 3 で count > 0 のチェック項目
- Step 3.5 で issues_found > 0 の場合
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

## Step 6: パイプライン課題検出 & トラッキング

Step 1-5 の結果と追加クエリを使い、`pipeline_issues` テーブルに課題を upsert する。

### 6a: 追加チェック

Step 1-5 で既に取得済みの情報に加え、以下を追加クエリ:

```sql
-- notification_drafts が24h以上 pending
SELECT id, notification_type, draft_date, created_at
FROM notification_drafts
WHERE status = 'pending'
  AND created_at < now() - interval '24 hours';
```

```sql
-- buyer_preference_summaries の鮮度
SELECT user_id,
       EXTRACT(DAY FROM now() - ai_calculated_at) AS days_stale
FROM buyer_preference_summaries
WHERE user_id = 'default';
```

```sql
-- 非アクティブ物件の画像URL残存（リンク切れ候補）
SELECT COUNT(*) AS stale_image_count
FROM enrichments e
JOIN listings l ON l.id = e.listing_id
WHERE l.is_active = false
  AND (e.suumo_images IS NOT NULL AND jsonb_array_length(e.suumo_images) > 0);
```

### 6b: 課題検出ルール

以下のルールに従い、該当する課題を `upsert_pipeline_issue()` で登録:

| issue_key | 検出条件 | severity | fix_type | category |
|---|---|---|---|---|
| `notification_drafts_stuck` | 6a で pending が1件以上 | critical | auto_fixable | notification |
| `scraping_no_new` | Step 2 の `new_listings_24h` = 0 | critical | manual | pipeline |
| `never_ai_analyzed` | Step 2 の `never_ai_analyzed` ≥ 10 | high | monitoring_only | data_quality |
| `enrichment_coverage_drop` | 前回 health_check の同フィールド coverage_pct との差が10pp以上低下 | high | manual | data_quality |
| `score_mismatch` | Step 3 の `score_mismatch_ls_no_ai` ≥ 50 | medium | monitoring_only | data_quality |
| `buyer_prefs_stale` | 6a で days_stale ≥ 7 | low | auto_fixable | data_quality |
| `log_files_large` | ローカルの `.claude/routines/logs/` 内ファイルが 100KB 超 | low | auto_fixable | maintenance |
| `fuzzy_dedup_missed` | Step 3.5 で表記揺れ重複を検出 | high | auto_fixable | data_quality |
| `promotional_name` | Step 3.5 で name にプロモーション文言残存 | medium | auto_fixable | data_quality |
| `homes_images_backlog_large` | Step 1 の homes 画像取得率が 30% 未満 | high | auto_fixable | data_quality |
| `homes_waf_continuous_failure` | ルーティン① Step 5 で WAF 連続ブロック | high | manual | pipeline |
| `image_urls_stale` | 非アクティブ物件の画像URLが enrichments に残存（50件以上） | low | auto_fixable | maintenance |

各 issue の `description` には現在値・傾向・推定解消時期を含める。
`suggested_fix` には Claude Code で実行可能な修正指示を含める。

例:
```sql
SELECT upsert_pipeline_issue(
  'notification_drafts_stuck',
  'critical',
  'notification',
  '通知ドラフト未送信',
  '3件の new_listing_digest が48h以上 pending（5/16, 5/17, 5/18分）',
  '{"stuck_count": 3, "oldest_date": "2026-05-16"}'::jsonb,
  'notification_drafts テーブルの pending レコードを再送信して',
  'auto_fixable'
);
```

### 6c: 自動解決

今回検出された issue_key のリストを配列にまとめ、それ以外の open issue を自動解決:

```sql
SELECT auto_resolve_stale_issues(ARRAY['notification_drafts_stuck', 'never_ai_analyzed', ...]::text[]);
```

---

## Step 7: Slack 健全性レポート（Claude Code コピペ用プロンプト形式）

open issue が1件以上ある場合のみ実行。0件の場合はスキップ。

1. open issue を取得:
```sql
SELECT * FROM get_open_pipeline_issues();
```

2. 以下のフォーマットで Slack メッセージを生成:

```
🔧 *パイプライン健全性レポート*（{日付}）
open issue: {件数}件（🔴{critical数} 🟡{high数} 🔵{medium数} 🟢{low数}）

---

以下を Claude Code にコピペしてください:

` ` `
パイプラインの以下の問題を修正して:

1. 🔴 {title}（{severity} / {fix_type}）
   {description}
   → {suggested_fix}

2. 🟡 {title}（{severity} / {fix_type}）
   {description}
   → {suggested_fix}

...
` ` `
```

※ コードブロック内の ` ` ` は実際にはバッククォート3つ連続（Slack のコードブロック記法）

**severity アイコンマッピング**:
- critical → 🔴
- high → 🟡
- medium → 🔵
- low → 🟢

**fix_type による suggested_fix 表示**:
- `auto_fixable`: 具体的な修正アクションを記載
- `manual`: 「原因を調査して修正方針を提案して」
- `monitoring_only`: 「対応不要、経過観察」

3. notification_drafts に保存:
```sql
SELECT upsert_notification_draft(
  'slack',
  'pipeline_health_report',
  '<上記メッセージ>',
  '{"issue_count": N, "critical": X, "high": Y}'::jsonb
);
```

4. open issue が0件の場合:
```sql
SELECT skip_notification_draft('slack', 'pipeline_health_report');
```

---

## 完了レポート

全ステップ完了後、以下のテンプレートに値を埋めた**マークダウンブロック**をチャットに出力する。
ユーザーはこの出力をそのままログファイルにコピペするため、**余計なテキストを前後に付けず、テンプレート通りの出力のみ**を行うこと。

````markdown
## {YYYY-MM-DD HH:MM} JST - ルーティン③ 実行ログ

### Step 1: エンリッチメントカバレッジ（全X項目中Y項目基準未満）

| フィールド | カバレッジ | 基準 | 判定 |
|---|---|---|---|
| listing_score | XX.XX% | 70% | ✅/⚠️ |
| ai_recommendation_score | XX.XX% | 50% | ✅/⚠️ |
| commute_info | XX.XX% | 60% | ✅/⚠️ |
| hazard_info | XX.XX% | 35% | ✅/⚠️ |
| price_fairness_score | XX.XX% | 20% | ✅/⚠️ |
| ai_listing_score | XX.XX% | 10% | ✅/⚠️ |
| ai_price_fairness_score | XX.XX% | 10% | ✅/⚠️ |
| extracted_features | XX.XX% | 30% | ✅/⚠️ |
| image_categories | XX.XX% | 30% | ✅/⚠️ |
| ss_lookup_status | XX.XX% | 30% | ✅/⚠️ |
| suumo_images | XX.XX% | 60% | ✅/⚠️ |
| floor_plan_images | XX.XX% | 50% | ✅/⚠️ |

**homes 画像取得率**: XX.XX%（XX/XX件） ✅/⚠️

### Step 2: パイプライン鮮度
- new_listings_24h: X件 ✅/⚠️
- ai_analyzed_24h: X件 ✅/⚠️
- stale_ai_7d: X件 ✅/⚠️
- never_ai_analyzed: X件 ✅/⚠️
- no_enrichment_48h: X件 ✅/⚠️

### Step 3: データ品質
- score_mismatch_ls_no_ai: X件 ✅/⚠️
- images_no_categories: X件 ✅/⚠️
- duplicate_active: X件 ✅/⚠️

### Step 3.5: AI品質スイープ
- checked: X件、issues: X件 ✅/⚠️

### Step 4: アノマリ検出
- active_count_drop: X件 ✅/⚠️
- score_contradiction: X件 ✅/⚠️

### Step 5: health_check_logs 保存
- ID: X、alert_count: X

### Step 6: pipeline_issues
- upsert: {issue_key一覧}
- 自動解決: X件

### Step 7: notification_drafts
- pipeline_health_report = pending/skipped（ID: X）
````

---

## ファイル操作の禁止

リモート実行環境には GitHub への書き込み権限がないため、以下の操作は**すべて禁止**:
- ログファイルの読み書き・編集
- `git add` / `git commit` / `git push`
- GitHub MCP の `push_files` / `create_branch`

ログファイルの更新・ログローテーションはユーザーがローカル環境で行う。

---

## 共通ルール
- **サブエージェント委任禁止**: 全ステップの処理はメインエージェントのコンテキストで実行すること
- ヘルスチェックの失敗は他のチェックをブロックしない
- 全チェック完了後に1つの health_check_logs レコードを保存する
- 対象が0件のチェックも「0件」として報告する（スキップしない）
- **Step 7 の Slack 通知のみ例外**: pipeline_health_report を notification_drafts に保存し、GHA の slack_notify.py が送信する
- 日本語で回答すること
