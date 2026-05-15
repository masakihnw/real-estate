# ルーティン②: AI 分析 & バイヤーピック

- **スケジュール**: 毎日 JST 4:00
- **MCP**: Supabase（必須）
- **所要時間目安**: 20-40分
- **前提**: ルーティン①（データ準備）が先に完了していること

---

## 概要

ルーティン①で整備されたデータを使い、投資レコメンデーション・画像分析・バイヤー向けピックを生成する。

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

3. 対象物件取得（config の filter を使用）:
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('investment_summary', '<config jsonb>');
```

4. 各物件を分析: system_prompt をシステムプロンプトとして、user_prompt_template の `{buyer_profile}` にバイヤープロファイル、`{listing_data}` に物件データを埋め込んで分析。JSON で score, conclusion, flags, scenarios, action を生成。

5. 結果書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'investment_summary', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

---

## Step 2: 画像分析

1. プロンプト取得:
```sql
SELECT * FROM get_active_prompt('image_analyzer');
```

2. 対象取得:
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('image_analyzer');
```

3. 各物件の suumo_images 配列から画像 URL を取得し、各画像を Vision で分析。system_prompt に従い JSON 結果を生成: is_junk, category, quality_score, thumbnail_score, brief_description。

4. 物件ごとに全画像結果を配列にまとめて書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'image_analyzer', '<画像結果配列>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

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
- image_analyzer: X件処理（総画像Y枚、junk Z枚）
- buyer_picks: おすすめX件抽出、サマリー生成完了

エラーがあればエラー内容も報告。

---

## 共通ルール
- エラーが発生しても他の物件・ステップの処理は続行する
- 対象が0件のステップはスキップして次へ進む
- 日本語で回答すること
