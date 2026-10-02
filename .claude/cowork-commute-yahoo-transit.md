# Coworkタスク Yahoo路線情報で通勤時間を更新

> 現行の通勤時間更新は、`.claude/routines/routine_1_data_prep.md` のStep 3（`station_commute_times` マスタを参照する方式）で行っている。本文書はYahoo路線情報をWebFetchで引く旧手順である。リモート環境からYahoo TransitへアクセスするとHTTP 403になる。この経緯は、[codex-commute-research.md](./codex-commute-research.md) の背景に書いている。

## 概要

Supabase上のアクティブな物件について、Yahoo路線情報（WebFetch）で通勤時間を調べる。結果は `enrichments.commute_info` に書き戻す。

## オフィス情報

通勤先は2か所（slug は `playground` と `m3career`）。実住所と名称は環境変数 `COMMUTE_OFFICES_JSON` とSupabaseで管理する。このドキュメントには実住所を書かない。以下の手順内の `{playground_address}` と `{m3career_address}` は、実行時に注入する。

## 手順

### 1. 対象物件を取得

Supabase MCP（`execute_sql`、project_id は `dzhcumdmzskkvusynmyw`）で次を実行する。

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

### 2. 各物件の通勤時間を取得

各物件の `ss_address` を使い、WebFetchでYahoo路線情報を取得する。

playground
```
https://transit.yahoo.co.jp/search/result?from={ss_address}&to={playground_address}&type=4&dt={YYYYMMDD}&tm=0900
```

m3career
```
https://transit.yahoo.co.jp/search/result?from={ss_address}&to={m3career_address}&type=4&dt={YYYYMMDD}&tm=0900
```

- `{YYYYMMDD}` 次の平日の日付（土日祝を避ける）
- `type=4` 到着時刻を指定する
- `tm=0900` 朝9:00に到着する

WebFetchのプロンプトは次のとおり。

> 最初のルートの所要時間（何分）、乗り換え回数、主要経由駅を教えてください。

### 3. 結果をSupabaseに書き戻す

各物件について次を実行する。

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

### 4. サマリーを出力

処理が終わったら、次の形式でレポートする。

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

- `source` が `gmaps` または `yahoo_transit` の既存データがある物件はスキップする。
- Yahoo Transitが結果を返さない場合はスキップする（エラーログに記録する）。
- 所要時間が120分を超える場合は異常値としてスキップする。
- 1リクエストごとに数秒の間隔を空ける（レート制限対策）。
- Supabaseのproject_idは `dzhcumdmzskkvusynmyw`。
