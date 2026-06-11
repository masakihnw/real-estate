# Cowork タスク: Yahoo路線情報で通勤時間を更新

## 概要

Supabase上のアクティブな物件に対して、Yahoo路線情報（WebFetch）で通勤時間を調べ、`enrichments.commute_info` に書き戻す。

## オフィス情報

- **playground**: 千代田区一番町4-6（Playground株式会社）
- **m3career**: 港区虎ノ門4-1-28（エムスリーキャリア株式会社）

## 手順

### 1. 対象物件を取得

Supabase MCP (`execute_sql`, project_id: `dzhcumdmzskkvusynmyw`) で以下を実行:

```sql
SELECT l.id, l.ss_address, l.name
FROM listings l
LEFT JOIN enrichments e ON e.listing_id = l.id
WHERE l.is_active = true
  AND l.ss_address IS NOT NULL
  AND (
    e.commute_info IS NULL
    OR e.commute_info->'playground'->>'source' NOT IN ('gmaps', 'yahoo_transit')
    OR e.commute_info->'m3career'->>'source' NOT IN ('gmaps', 'yahoo_transit')
  )
ORDER BY l.updated_at DESC
LIMIT 20;
```

### 2. 各物件に対して通勤時間を取得

各物件の `ss_address` を使い、WebFetch で Yahoo路線情報を取得:

**playground:**
```
https://transit.yahoo.co.jp/search/result?from={ss_address}&to=千代田区一番町4-6&type=4&dt={YYYYMMDD}&tm=0900
```

**m3career:**
```
https://transit.yahoo.co.jp/search/result?from={ss_address}&to=港区虎ノ門4-1-28&type=4&dt={YYYYMMDD}&tm=0900
```

- `{YYYYMMDD}`: 次の平日の日付（土日祝を避ける）
- `type=4`: 到着時刻指定
- `tm=0900`: 朝9:00到着

WebFetch のプロンプト:
> 最初のルートの所要時間（何分）、乗り換え回数、主要経由駅を教えてください。

### 3. 結果を Supabase に書き戻し

各物件に対して:

```sql
UPDATE enrichments 
SET commute_info = jsonb_build_object(
  'playground', jsonb_build_object(
    'minutes', {PG分数},
    'summary', 'Yahoo路線情報 (朝9:00到着, {経由駅}, 乗換{N}回)',
    'calculatedAt', '{ISO8601 UTC}',
    'source', 'yahoo_transit'
  ),
  'm3career', jsonb_build_object(
    'minutes', {M3分数},
    'summary', 'Yahoo路線情報 (朝9:00到着, {経由駅}, 乗換{N}回)',
    'calculatedAt', '{ISO8601 UTC}',
    'source', 'yahoo_transit'
  )
)
WHERE listing_id = {id};
```

### 4. サマリー出力

処理完了後、以下の形式でレポート:

```
=== Yahoo Transit 通勤時間更新 ===
日時: YYYY-MM-DD HH:MM JST
対象: N件

| ID | 物件名 | PG(分) | M3(分) | 状態 |
|----|--------|--------|--------|------|
| ... | ... | ... | ... | OK/SKIP/ERROR |

成功: X件, スキップ: Y件, エラー: Z件
```

## ルール

- `source` が `gmaps` または `yahoo_transit` の既存データがある物件は**スキップ**
- Yahoo Transit が結果を返さない場合はスキップ（エラーログに記録）
- 所要時間が 120分を超える場合は異常値として SKIP
- 1リクエストごとに数秒の間隔を空ける（レート制限対策）
- Supabase project_id: `dzhcumdmzskkvusynmyw`
