# ルーティン①: データ準備 & スコアリング

- **スケジュール**: 毎日 JST 2:00
- **MCP**: Supabase（必須）
- **所要時間目安**: 15-30分

---

## 概要

不動産物件データのクレンジング・エンリッチメントを行う。
後続のルーティン②（AI分析 & ピック）が依存するため、先に実行する。

Supabase project_id: `dzhcumdmzskkvusynmyw`
全ての SQL は Supabase MCP の `execute_sql` で実行すること。

---

## Step 1: セマンティック重複排除

1. プロンプト取得:
```sql
SELECT * FROM get_active_prompt('dedup');
```

2. 対象取得:
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('dedup');
```

3. 各ペアについて system_prompt に従い分析。user_prompt_template のプレースホルダーに物件A/Bの情報を埋め込む。

4. 結果書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'dedup', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

対象がなければスキップして Step 2 へ。

---

## Step 2: テキスト特徴抽出

1. プロンプト取得:
```sql
SELECT * FROM get_active_prompt('text_enricher');
```

2. 対象取得:
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('text_enricher');
```

3. 各物件について system_prompt に従い分析。user_prompt_template のプレースホルダー（{name}, {address}, {layout}, {area_m2}, {built_year}, {floor_position}, {floor_total}, {total_units}, {management_fee}, {repair_reserve_fund}, {feature_tags}, {remarks}, {equipment}）に listing_data のフィールドを埋め込む。値が null の場合は「不明」と記載。

4. 結果書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'text_enricher', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

対象がなければスキップして Step 3 へ。

---

## Step 3: AI 動的スコアリング

1. プロンプト取得:
```sql
SELECT * FROM get_active_prompt('ai_scoring');
```

2. 対象取得:
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('ai_scoring');
```

3. 各物件について system_prompt に従い、listing_data 全体を渡して listing_score (0-100) と price_fairness_score (0-100) を算出。定量データ（価格、面積、築年、駅距離、ハザード等）と定性データ（テキスト特徴、設備、管理状態）の両方を考慮する。

4. 結果書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'ai_scoring', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

対象がなければスキップして Step 4 へ。

---

## Step 4: 通勤時間更新（Yahoo Transit）

1. 対象取得:
```sql
SELECT l.id, l.name, l.address, ls.station_name, ls.station_line, ls.walk_min
FROM listings l
JOIN listing_sources ls ON ls.listing_id = l.id
LEFT JOIN enrichments e ON e.listing_id = l.id
WHERE l.is_active = true
  AND (e.commute_info IS NULL OR NOT (e.commute_info ? 'yahoo_transit'))
ORDER BY l.created_at DESC
LIMIT 20;
```

2. 各物件の最寄り駅から2つのオフィスへの通勤時間を WebFetch で取得:
   - playground（半蔵門駅）: `https://transit.yahoo.co.jp/search/result?from={最寄り駅}&to=半蔵門&type=1&ticket=ic&expkind=1&ws=3&s=0`
   - m3career（神谷町駅）: `https://transit.yahoo.co.jp/search/result?from={最寄り駅}&to=神谷町&type=1&ticket=ic&expkind=1&ws=3&s=0`

3. HTML から所要時間・乗り換え回数・運賃・ルート概要をパース。

4. 結果書き戻し:
```sql
UPDATE enrichments SET
  commute_info = jsonb_build_object(
    'yahoo_transit', jsonb_build_object(
      'playground', jsonb_build_object('duration_min', X, 'transfers', Y, 'fare_ic', Z, 'route_summary', '...', 'walk_min', W),
      'm3career', jsonb_build_object('duration_min', X, 'transfers', Y, 'fare_ic', Z, 'route_summary', '...', 'walk_min', W)
    ),
    'total_playground_min', <walk+duration>,
    'total_m3career_min', <walk+duration>,
    'updated_at', now()::text
  )
WHERE listing_id = <id>;
```

対象がなければスキップ。

---

## 完了レポート

各ステップの処理件数をまとめて報告:
- dedup: X件処理（auto-merge Y件、flag Z件）
- text_enricher: X件処理
- ai_scoring: X件処理（平均スコア XX）
- commute: X件処理

エラーがあればエラー内容も報告。

---

## 共通ルール
- エラーが発生しても他の物件・ステップの処理は続行する
- 対象が0件のステップはスキップして次へ進む
- 日本語で回答すること
