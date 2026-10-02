# ルーティン④: ヘルスモニタリング

- スケジュール: 毎日JST 7:00（1回/日）
- MCP: Supabase（必須）
- 所要時間目安: 5-10分
- 前提: ルーティン①（JST 3:00）②（JST 4:00）③（JST 5:30）が完了済みであること

---

## 概要

データパイプラインの健全性を監視し、結果を`health_check_logs`テーブルに保存する。
ルーティン①②③がStep 0で`get_latest_health_check()`を参照し、問題があれば自律的に修正する。
このルーティンはSlack通知を行わず、DBへの保存だけを行う（Step 7の通知ドラフト保存を除く）。

Supabase project_id: `dzhcumdmzskkvusynmyw`
全てのSQLはSupabase MCPの`execute_sql`で実行する。

---

## Step 1: エンリッチメントカバレッジ

```sql
SELECT * FROM health_check_enrichment_coverage();
```

結果テーブルを確認する。列はfield_name, total_active, non_null_count, coverage_pctである。

最低基準は次の表のとおり。

| フィールド | 基準 | 備考 |
|---|---|---|
| listing_score | 70% | |
| ai_recommendation_score | 50% | |
| commute_info | 60% | |
| hazard_info | 35% | ハザードデータソース依存 |
| price_fairness_score | 20% | sumai surfinカバレッジ依存 |
| ai_listing_score | 10% | ルーティン②の実行で増加中（2週間後に基準を見直す） |
| ai_price_fairness_score | 10% | ルーティン②の実行で増加中（2週間後に基準を見直す） |
| extracted_features | 30% | |
| image_categories | 30% | |
| ss_lookup_status | 30% | |
| suumo_images | 60% | 物件写真の取得率 |
| floor_plan_images | 50% | 間取り図の取得率 |

最低基準未満のフィールドは「⚠️」、基準以上のフィールドは「✅」としてレポートに記録する。

`health_check_enrichment_coverage()`に`suumo_images` / `floor_plan_images`が含まれない場合、次のカスタムクエリで補う。

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

さらに、homes物件に限った画像取得率も確認する。

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

homes画像取得率が30%未満の場合は「⚠️」として記録し、Step 6bの`homes_images_backlog_large` issueとして登録する。

結果を次の構造で保持する。
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

結果メトリクスは次のとおり。
- `new_listings_24h`: 0件の場合はスクレイピングパイプラインの異常として警告する
- `ai_analyzed_24h`: `new_listings_24h`の50%未満ならAIパイプラインの遅延として警告する
- `stale_ai_7d`: 10件以上なら再分析を推奨する
- `never_ai_analyzed`: 5件以上なら警告する
- `no_enrichment_48h`: 1件以上なら警告する

結果を次の構造で保持する。
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

結果の確認項目は次のとおり。
- `score_mismatch_ls_no_ai`: listing_scoreはあるがAI推薦スコアがない。ルーティン③ Step 1の対象漏れの可能性がある
- `images_no_categories`: 画像はあるがカテゴリがない。ルーティン② Step 2の対象漏れの可能性がある
- `duplicate_active`: 重複したアクティブ物件がある。ルーティン① Step 1のdedupの対象漏れの可能性がある

結果を次の構造で保持する。
```json
{
  "score_mismatch_ls_no_ai": {"count": 3, "detail": "...", "ok": false},
  "images_no_categories": {"count": 0, "detail": "...", "ok": true},
  "duplicate_active": {"count": 0, "detail": "...", "ok": true}
}
```

---

## Step 3.5: AI品質スイープ

ルーティン①で漏れた品質問題を検出する確認ステップ。
修正は行わず、検出だけを行う。問題があれば`pipeline_issues`に登録し、次回のルーティン①で修正する。

1. 次のクエリで、品質に疑いのある物件を最大20件取得する。
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

1b. 名前の表記揺れによる重複を検出する（住所と築年は一致し、normalized_nameが異なるペア）。
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
  -- 丁目番号は全角（２）/半角（2）混在。\d の全角マッチは lc_ctype 依存のため [0-9０-９] で明示対応（防御的）
  AND SUBSTRING(l1.address FROM '.+?[区市].+?[0-9０-９]+') = SUBSTRING(l2.address FROM '.+?[区市].+?[0-9０-９]+')
  AND LENGTH(SUBSTRING(l1.address FROM '.+?[区市].+?[0-9０-９]+')) > 3
  AND LENGTH(l1.normalized_name) > 3
  AND LENGTH(l2.normalized_name) > 3
LIMIT 10;
```

検出されたペアは`fuzzy_dedup_missed_{id_a}_{id_b}`として`pipeline_issues`に登録する。
ルーティン① Step 0.7でAIが判定して修正する。

2. 取得した物件についてAIが判定する。
   a. 物件名品質: `name`にプロモーション文言が混入していないか？
   b. 表記揺れ重複: 同一住所・同一面積の別名物件が存在しないか？（1bの結果も参照）
   c. 異常データ: normalized_nameが明らかに物件名ではないもの
   d. 省略記号残存: 三点リーダー等がnormalized_nameに残っていないか？

3. 問題を見つけたら`pipeline_issues`に登録する。
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

   issue_keyの命名規則は次のとおり。
   - 表記揺れ重複: `fuzzy_dedup_missed_{id_a}_{id_b}`
   - プロモーション文言: `promotional_name_{id}`

結果を次の構造で保持する。
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

対象が0件なら「品質問題なし」と記録してスキップする。

---

## Step 4: アノマリ検出

```sql
SELECT * FROM health_check_anomaly_detection();
```

結果を次の構造で保持する。
```json
{
  "active_count_drop": {"value": 150, "threshold": 120, "is_alert": false, "detail": "..."},
  "score_contradiction": {"value": 0, "threshold": 0, "is_alert": false, "detail": "..."}
}
```

`is_alert = true`の項目を重点的に報告する。

注意: `active_count_drop`がアラートになった場合は、原因を確認する。意図的な一括非アクティブ化（例: 新築物件の廃止、条件変更による除外）でないかを調べる。直近のルーティン①の実行ログや`listing_events`テーブルに大量の`deactivated`イベントがあれば、誤検知として扱う。その場合は`pipeline_issues`に登録しない。

---

## Step 5: health_check_logs保存

全ステップの結果をまとめ、`health_check_logs`に保存する。

アラート一覧には次を集める。
- Step 1で基準未満のフィールド名
- Step 2で警告条件に該当したメトリクス
- Step 3でcount > 0のチェック項目
- Step 3.5でissues_found > 0の場合
- Step 4でis_alert = trueの項目

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

alerts配列の例を示す。
```json
[
  {"source": "coverage", "field": "ai_recommendation_score", "message": "42.0% < 基準50%"},
  {"source": "data_quality", "check": "score_mismatch_ls_no_ai", "message": "3件のスコア不整合"}
]
```

---

## Step 6: パイプライン課題検出 & トラッキング

Step 1-5の結果と追加クエリを使い、`pipeline_issues`テーブルに課題をupsertする。

### 6a: 追加チェック

Step 1-5で取得済みの情報に加え、次のクエリを実行する。

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

スクレイパー健全性メトリクス: GHAが毎ラン更新してコミットするJSONを取得する。

次のURLをWeb fetchで取得する（publicリポジトリのため認証は不要）。

```
https://raw.githubusercontent.com/masakihnw/real-estate/main/scraping-tool/results/scraper_metrics.json
```

形式: `{"metrics": {"suumo": {"parsed": N, "parse_failures": N, "empty_pages": N}, ...}, "alerts": ["..."]}`

- `alerts`配列が空でない場合は、6bの`scraper_parse_health` issueを登録する
- fetchに失敗した場合とファイルが存在しない場合は、スキップする。初回ランの前や一時的なネットワーク要因が考えられるので、issueにしない
- `metrics`が空の`{}`の場合もスキップする（メトリクスを収集していないランがあるだけで、異常ではない）

```sql
-- 非アクティブ物件の画像URL残存（リンク切れ候補）
SELECT COUNT(*) AS stale_image_count
FROM enrichments e
JOIN listings l ON l.id = e.listing_id
WHERE l.is_active = false
  AND (e.suumo_images IS NOT NULL AND jsonb_array_length(e.suumo_images) > 0);
```

サイト別sync挿入数の回帰検知: `scraping_runs`テーブル（sync層）を使う。

```sql
SELECT * FROM detect_source_insertion_anomalies();
```

返却された各`source`は、基準期間（〜10日前）には挿入していたサイトである。直近72hの真新規（new+reappeared）は0件である。
sync側でエラーを出さずに挿入が止まった回帰の候補になる。
- 1件以上返れば、6bの`source_insertion_zero_<source>` issueをsourceごとに登録する
- 0件なら正常なのでスキップする
- scraper_metrics.json（パース層）や合算の`new_listings_24h`では、サイト単独のゼロは見つからない。この検知は、そのゼロを検出する。パースは成功している。他サイトの挿入が続くため、合算値には現れない（例: suumoが6/17以降、真新規ゼロになったsync側の回帰）

### 6b: 課題検出ルール

次のルールに従い、該当する課題を`upsert_pipeline_issue()`で登録する。

| issue_key | 検出条件 | severity | fix_type | category |
|---|---|---|---|---|
| `notification_drafts_stuck` | 6aでpendingが1件以上 | critical | auto_fixable | notification |
| `scraping_no_new` | Step 2の`new_listings_24h` = 0 | critical | manual | pipeline |
| `never_ai_analyzed` | Step 2の`never_ai_analyzed` ≥ 10 | high | monitoring_only | data_quality |
| `enrichment_coverage_drop` | 前回health_checkの同フィールドcoverage_pctとの差が10pp以上低下 | high | manual | data_quality |
| `score_mismatch` | Step 3の`score_mismatch_ls_no_ai` ≥ 50 | medium | monitoring_only | data_quality |
| `buyer_prefs_stale` | 6aでdays_stale ≥ 7 | low | auto_fixable | data_quality |
| `log_files_large` | ローカルの`.claude/routines/logs/`内ファイルが100KB超 | low | auto_fixable | maintenance |
| `fuzzy_dedup_missed` | Step 3.5で表記揺れ重複を検出 | high | auto_fixable | data_quality |
| `promotional_name` | Step 3.5でnameにプロモーション文言残存 | medium | auto_fixable | data_quality |
| `homes_images_backlog_large` | Step 1のhomes画像取得率が30%未満 | high | auto_fixable | data_quality |
| `homes_waf_continuous_failure` | HOME'S画像取得でWAF連続ブロック（ルーティン① Step 5は廃止済み。GitHub Actionsの`backfill-homes-images`は無効化されているため、現在の取得経路は`run_enrich.sh` Track G） | high | manual | pipeline |
| `image_urls_stale` | 非アクティブ物件の画像URLがenrichmentsに残存（50件以上） | low | auto_fixable | maintenance |
| `scraper_parse_health` | 6aのscraper_metrics.jsonの`alerts`が1件以上（パース失敗率30%以上or空ページ3回以上） | high | manual | pipeline |
| `source_insertion_zero_<source>` | 6aの`detect_source_insertion_anomalies()`が当該sourceを返す（直近72h真新規ゼロ・基準期間はproductive） | critical | manual | pipeline |

各issueの`description`には、現在値、傾向、推定解消時期を書く。
`suggested_fix`には、Claude Codeで実行できる修正指示を書く。

`scraper_parse_health`の例を示す（descriptionにはalertsの内容をそのまま列挙する）。
```sql
SELECT upsert_pipeline_issue(
  'scraper_parse_health',
  'high',
  'pipeline',
  'スクレイパーパース健全性の劣化',
  'suumo: パース失敗率 40%（120/300件） — HTML構造変更の可能性',
  '{"alerts": ["suumo: パース失敗率 40%..."], "metrics": {"suumo": {"parsed": 180, "parse_failures": 120}}}'::jsonb,
  '該当スクレイパーの parse_list_html のセレクタが現行HTMLと一致しているか調査して修正方針を提案して',
  'manual'
);
```

`source_insertion_zero_<source>`の例（`detect_source_insertion_anomalies()`の返却1行が1 issueになる。
`<source>`は実際のサイト名に置き換える）。
```sql
SELECT upsert_pipeline_issue(
  'source_insertion_zero_suumo',
  'critical',
  'pipeline',
  'suumo の真新規挿入が停止',
  'suumo: 直近72hの真新規（new+reappeared）0件（recent_runs=9）。基準期間は 21件挿入 — sync側回帰の可能性',
  '{"source": "suumo", "recent_inserts": 0, "recent_runs": 9, "baseline_inserts": 21, "baseline_runs": 30}'::jsonb,
  'supabase_sync.py の identity_key 解決（URL一致で既存に誤収束していないか）と sync 経路を調査して。scraper_metrics.json が緑ならパースは正常＝sync 側の回帰',
  'manual'
);
```

検出された各`source_insertion_zero_<source>`キーは、6cの`auto_resolve_stale_issues`の
検出済み配列に必ず含める。含めないと翌ランですぐresolveされ、回帰が続いていても通知が消える。

`notification_drafts_stuck`の例を示す。
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

今回検出したissue_keyを配列にまとめ、それ以外のopen issueを自動解決する。

```sql
SELECT auto_resolve_stale_issues(ARRAY[
  'notification_drafts_stuck',
  'never_ai_analyzed',
  -- 6a の detect_source_insertion_anomalies() が返した各 source の
  -- 'source_insertion_zero_<source>' キーを必ずここに列挙する（例: 'source_insertion_zero_suumo'）。
  -- 列挙漏れすると翌ラン即 resolve され、回帰継続中でも通知が消える
  ...
]::text[]);
```

---

## Step 7: Slack健全性レポート（Claude Codeコピペ用プロンプト形式）

open issueが1件以上ある場合だけ実行する。0件の場合はスキップする。

1. open issueを取得する。
```sql
SELECT * FROM get_open_pipeline_issues();
```

2. 次のフォーマットでSlackメッセージを生成する。

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

コードブロック内の` ` `は、実際にはバッククォート3つの連続である（Slackのコードブロック記法）。

severityアイコンマッピング。
- critical → 🔴
- high → 🟡
- medium → 🔵
- low → 🟢

fix_typeによるsuggested_fix表示。
- `auto_fixable`: 具体的な修正アクションを書く
- `manual`: 「原因を調査して修正方針を提案して」
- `monitoring_only`: 「対応不要、経過観察」

3. notification_draftsに保存する。
```sql
SELECT upsert_notification_draft(
  'slack',
  'pipeline_health_report',
  '<上記メッセージ>',
  '{"issue_count": N, "critical": X, "high": Y}'::jsonb
);
```

4. open issueが0件の場合は次を実行する。
```sql
SELECT skip_notification_draft('slack', 'pipeline_health_report');
```

---

## 完了レポート

全ステップの完了後、次のテンプレートに値を埋めたマークダウンブロックをチャットに出力する。
ユーザーはこの出力をそのままログファイルにコピペする。前後にテキストを付けず、テンプレート通りに出力する。

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

リモート実行環境にはGitHubへの書き込み権限がないので、次の操作は**すべて禁止**する。
- ログファイルの読み書き・編集
- `git add` / `git commit` / `git push`
- GitHub MCPの`push_files` / `create_branch`

ログファイルの更新・ログローテーションはユーザーがローカル環境で行う。

---

## 共通ルール
- サブエージェント委任禁止: 全ステップの処理をメインエージェントのコンテキストで実行する
- ヘルスチェックの失敗は他のチェックをブロックしない
- 全チェック完了後に1つのhealth_check_logsレコードを保存する
- 対象が0件のチェックも「0件」として報告する（スキップしない）
- Step 7のSlack通知だけは例外とする。pipeline_health_reportをnotification_draftsに保存する。送信はGHAのslack_notify.pyが行う
- 日本語で回答する
