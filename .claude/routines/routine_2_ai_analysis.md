# ルーティン②: AI 分析 & バイヤーピック

- **スケジュール**: 毎日 JST 4:00
- **MCP**: Supabase（必須）
- **所要時間目安**: 20-40分
- **前提**: 不動産データ準備 & スコアリングが先に完了していること

---

## 概要

不動産データ準備 & スコアリングで整備されたデータを使い、投資レコメンデーション・画像分析・バイヤー向けピックを生成する。

Supabase project_id: `dzhcumdmzskkvusynmyw`
全ての SQL は Supabase MCP の `execute_sql` で実行すること。

---

## Step 1: 投資レコメンデーション

1. プロンプト取得:
```sql
SELECT * FROM get_active_prompt('investment_summary');
```

2. バイヤープロファイル取得:
```sql
SELECT * FROM buyer_profiles LIMIT 1;
```
→ 全フィールド（family_composition, household_income, work_style, child_plan, priorities, current_housing, commute_quality, deal_breakers, self_funds, planned_borrowing, interest_type, estimated_rate, repayment_years, monthly_payment_limit, relocation_reason, post_sale_strategy, timeline, risk_tolerance 等）を日本語テキストにフォーマット。

3. 対象物件取得（全アクティブ物件のうち未分析 or プロンプト変更分）:
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('investment_summary');
```
→ 最大80件/回。新着順。未分析が0件になるまで毎日の実行で全件カバーする。

4. 各物件を分析: system_prompt をシステムプロンプトとして、user_prompt_template の `{buyer_profile}` にバイヤープロファイル、`{listing_data}` に物件データを埋め込んで分析。JSON で score, conclusion, flags, scenarios, action を生成。

5. 結果書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'investment_summary', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

---

## Step 2: 画像分析 & 不要画像クリーンアップ

**方針**: Supabase Storage URL は Vision でアクセスできないため、suumo_images の `label` フィールドを使ったラベルベース分類を行う。分類後、不要画像は DB から削除する。

### Step 2a: 画像分類

1. プロンプト取得:
```sql
SELECT * FROM get_active_prompt('image_analyzer');
```

2. 対象取得:
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('image_analyzer');
```

→ listing_data には `id`, `name`, `suumo_images` のみが含まれる（軽量ペイロード）。

3. 各物件の `suumo_images` 配列（`{url, label}` の配列）から `label` を読み取り、以下のマッピングで分類:

| label パターン | category | is_junk |
|---|---|---|
| 間取図、間取り | floor_plan | false |
| 外観、エントランス | exterior | false |
| 室内、リビング、居室、キッチン、ダイニング、和室、洋室、LDK、DK | interior | false |
| 浴室、バス、トイレ、洗面、水回り、脱衣 | water | false |
| 眺望、バルコニー、ベランダ、展望 | view | false |
| 共用部、エントランスホール、中庭、ロビー、ジム、ラウンジ | common_area | false |
| 周辺、公園、学校、スーパー、商業、駅前 | surroundings | false |
| 上記いずれにも該当しない or 明らかに広告・バナー・ロゴ・アイコン | junk | true |

- quality_score と thumbnail_score は label から推定:
  - 外観全体・明るいリビング → thumbnail_score 高 (0.8-0.9)
  - 間取り図 → quality_score 高だが thumbnail_score 低 (0.2-0.3)
  - クローゼット内部・設備アップ → 両方中程度 (0.4-0.6)
- brief_description は label をそのまま使用

4. 物件ごとに全画像結果を配列にまとめて書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'image_analyzer', '<画像結果配列>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

### Step 2b: 不要画像の削除

**重要**: Step 2a の全物件の upsert_ai_enrichment が完了したことを確認してから実行すること。

分類完了後、junk 画像を DB から一括削除:
```sql
SELECT * FROM batch_cleanup_junk_images();
```

→ `is_junk = true` または `category = 'junk'` の画像を `suumo_images` と `image_categories` の両方から除去。結果は `(listing_id, removed_count)` の配列。

対象がなければスキップして Step 3 へ。

---

## Step 3: バイヤーピック & デイリーブリーフ

1. プロンプト取得:
```sql
SELECT * FROM get_active_prompt('buyer_picks');
```

2. バイヤープロファイル取得:
```sql
SELECT * FROM buyer_profiles LIMIT 1;
```

3. スコア上位のアクティブ物件を取得（AI スコアリング結果を活用）:
```sql
SELECT lf.id, lf.name, lf.address, lf.layout, lf.area_m2, lf.price_man,
       lf.walk_min, lf.station_line, lf.built_year, lf.ownership,
       lf.listing_score, lf.price_fairness_score,
       e.ai_listing_score, e.ai_price_fairness_score,
       e.ai_recommendation_score, e.ai_recommendation_summary,
       e.ai_recommendation_flags, e.extracted_features,
       lf.first_seen_at, lf.commute_info
FROM listings_feed lf
LEFT JOIN enrichments e ON e.listing_id = lf.id
WHERE lf.is_active = true
ORDER BY COALESCE(e.ai_listing_score, lf.listing_score, 0) DESC
LIMIT 50;
```

4. system_prompt に従い、バイヤープロファイルと物件リストを照合:
   - おすすめ物件を最大10件抽出しランク付け
   - 各物件の推薦理由を1-2文で生成
   - マーケットインサイトを生成
   - iOS アプリ用のサマリーテキストを生成

5. 結果を buyer_daily_briefs に保存:
```sql
INSERT INTO buyer_daily_briefs (user_id, brief_date, summary_text, recommended_listings, market_insights, ai_model, ai_prompt_hash)
VALUES (
  '<user_id>',
  CURRENT_DATE,
  '<summary_text>',
  '<recommended_listings JSON>'::jsonb,
  '<market_insights>',
  'claude-sonnet-4-6',
  '<prompt_hash>'
)
ON CONFLICT (user_id, brief_date)
DO UPDATE SET
  summary_text = EXCLUDED.summary_text,
  recommended_listings = EXCLUDED.recommended_listings,
  market_insights = EXCLUDED.market_insights,
  ai_model = EXCLUDED.ai_model,
  ai_prompt_hash = EXCLUDED.ai_prompt_hash,
  created_at = now();
```

---

## 完了レポート

各ステップの処理件数をまとめて報告:
- investment_summary: X件処理（スコア分布: 5=X件, 4=X件, 3=X件, 2=X件, 1=X件）
- image_analyzer: X件処理（総画像Y枚、junk Z枚削除済み）
- buyer_picks: おすすめX件抽出、サマリー生成完了

各ステップの全物件処理結果を以下のテーブル形式で記録:
```
| # | listing_id | name | status | score | error |
```
- status: ok / error
- score: investment_summary の場合は recommendation_score
- error: エラーがあればエラー内容

---

## 共通ルール
- **サブエージェント委任禁止**: 全ステップの処理はメインエージェントのコンテキストで実行すること。サブエージェント（Agent ツール）への委任は禁止
- エラーが発生しても他の物件・ステップの処理は続行する
- 対象が0件のステップはスキップして次へ進む
- 日本語で回答すること
