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

## Step 0: ヘルスチェック参照（自律修正）

直近のヘルスチェック結果を確認し、Routine 1 の処理に影響するアラートがあれば対応する。

```sql
SELECT * FROM get_latest_health_check();
```

**確認項目と対応**:

| alerts.source | 該当チェック | 対応アクション |
|---|---|---|
| `data_quality` / `duplicate_active` | 重複アクティブ物件あり | Step 1 の dedup で優先的に処理されるため、件数を意識して確認 |
| `freshness` / `no_enrichment_48h` | 48h以上エンリッチメントなし | Step 2-4 で該当物件が処理されるよう注視 |
| `freshness` / `stale_ai_7d` | AI分析が7日以上古い | Step 3 で再スコアリング対象に含まれているか確認 |
| `coverage` / 基準未満フィールド | エンリッチメント不足 | 該当 Step で処理漏れがないか確認 |

- check_date が2日以上前の場合、Routine 3 が未実行の可能性があるため警告を報告（処理は続行）
- 結果が0件（Routine 3 未実行）の場合はスキップして Step 1 へ進む

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

→ listing_data には物件の基本情報に加え、`group_members` 配列が含まれる。
`group_members` は同一マンション内の候補物件リスト（normalized_name 一致 or 住所+階数+総戸数一致）。

3. **ペア比較の方法**: listing_data の物件（親）と `group_members` 内の各物件（候補）を1対1で比較する。
   - 親物件の情報: listing_data のトップレベルフィールド（name, normalized_name, layout, area_m2, floor_position 等）
   - 候補物件の情報: `group_members` 配列内の各オブジェクト
   - `group_members` が null または空配列の場合はスキップ
   - 各ペアについて system_prompt に従い分析。user_prompt_template の物件A に親物件、物件B に候補物件を埋め込む

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

→ `feature_tags IS NOT NULL` のアクティブ物件のみ返される。feature_tags が空の物件は対象外。

3. 各物件について system_prompt に従い分析。user_prompt_template のプレースホルダーに listing_data のフィールドを埋め込む。
   - listings_feed に存在するフィールド: name, address, layout, area_m2, built_year, floor_position, floor_total, total_units, management_fee, repair_reserve_fund, feature_tags, key_strengths, key_risks, ownership, direction, parking 等
   - **注意**: `remarks` や `equipment` は listings_feed に存在しない。テンプレートに含まれていても null として扱う
   - 値が null の場合は「不明」と記載

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

→ 同一 normalized_name の物件は DISTINCT ON で重複排除済み（同一マンションの複数ページを何度もスコアリングしない）。
→ ai_prompt_hash が変更されていない物件もスキップされる。

3. 各物件について system_prompt に従い、listing_data 全体を渡して総合適合スコア listing_score (0-100) と price_fairness_score (0-100) を算出。system_prompt にはバイヤープロファイル（家族構成・予算・通勤・間取り要件等）が組み込まれており、「この家族にとっての適合度」を6軸（通勤・予算・間取り・立地・建物品質・資産性）で評価する。結果は listing_score に直接書き込まれ iOS アプリのソート順に反映される。

4. 結果書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'ai_scoring', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

対象がなければスキップして Step 4 へ。

---

## Step 4: 通勤時間更新（マスタ参照方式）

**方針**: `station_commute_times` マスタテーブル（330駅+）と `batch_update_commute_from_master()` RPC を使い、物件の最寄り駅から2オフィスへの通勤時間を一括更新する。API/WebFetch は使用しない。

1. バッチ更新の実行:
```sql
SELECT * FROM batch_update_commute_from_master(100);
```

→ 結果は `(listing_id, station_name, status)` の配列。status は `updated`, `not_in_master`, `parse_failed` のいずれか。

2. `not_in_master` の駅がある場合:
   - 同一路線の隣接駅データをマスタから探して推定値を INSERT し、再度バッチ実行
   - 推定値は `source = 'estimated_from_nearby'`, `confidence = 'estimated'` で記録
   - 推定が難しい駅はリストとして報告（Cowork での手動補完用）

3. 結果が0件になるまで繰り返す（1回あたり最大100件）。

対象がなければスキップ。

---

## 完了レポート

各ステップの処理件数をまとめて報告:
- dedup: X件処理（auto-merge Y件、flag Z件）
- text_enricher: X件処理
- ai_scoring: X件処理（平均スコア XX）
- commute: X件処理（マスタヒット Y件、推定 Z件、未登録 W駅）

各ステップの全物件処理結果を以下のテーブル形式で記録:
```
| # | listing_id | name | status | score | error |
```
- status: ok / error
- score: ai_scoring の場合は listing_score、text_enricher の場合は省略可
- error: エラーがあればエラー内容

---

## 共通ルール
- **サブエージェント委任禁止**: 全ステップの処理はメインエージェントのコンテキストで実行すること。サブエージェント（Agent ツール）への委任は禁止
- エラーが発生しても他の物件・ステップの処理は続行する
- 対象が0件のステップはスキップして次へ進む
- 日本語で回答すること
