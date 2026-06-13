# ルーティン③: AI 分析 & バイヤーピック

- **スケジュール**: 毎日 JST 5:30（1回/日）
- **MCP**: Supabase（必須）
- **所要時間目安**: 20-30分/回
- **前提**: ルーティン②（JST 4:00）が完了済みであること

---

## 概要

不動産データ準備 & スコアリングで整備されたデータを使い、投資レコメンデーション・画像分析・バイヤー向けピックを生成する。

Supabase project_id: `dzhcumdmzskkvusynmyw`
全ての SQL は Supabase MCP の `execute_sql` で実行すること。

---

## Step 0: ヘルスチェック参照（自律修正）

直近のヘルスチェック結果を確認し、Routine 2 の処理に影響するアラートがあれば対応する。

```sql
SELECT * FROM get_latest_health_check();
```

**確認項目と対応**:

| alerts.source | 該当チェック | 対応アクション |
|---|---|---|
| `data_quality` / `score_mismatch_ls_no_ai` | listing_score有だが AI推薦スコア無 | Step 1 で該当物件が処理対象に含まれるか確認。含まれていなければ手動で追加検討 |
| `data_quality` / `images_no_categories` | 画像ありだがカテゴリなし | Step 2 で該当物件が処理対象に含まれるか確認 |
| `coverage` / `ai_recommendation_score` 基準未満 | AI推薦スコアのカバレッジ不足 | Step 1 の処理件数上限（80件）を意識し、未分析物件を優先 |
| `coverage` / `image_categories` 基準未満 | 画像カテゴリのカバレッジ不足 | Step 2 の処理で改善を確認 |
| `freshness` / `never_ai_analyzed` | アクティブだがAI未分析 | Step 1 で処理されるべき物件。対象取得 RPC が返す件数と照合 |

- check_date が2日以上前の場合、Routine 3 が未実行の可能性があるため警告を報告（処理は続行）
- 結果が0件（Routine 3 未実行）の場合はスキップして Step 1 へ進む

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
→ 最大20件/回。新着順。未分析が0件になるまで毎日の実行で全件カバーする。

4. 各物件を **1件ずつ AI 分析**: system_prompt をシステムプロンプトとして、user_prompt_template の `{buyer_profile}` にバイヤープロファイル、`{listing_data}` に物件データを埋め込んで分析。JSON で score, conclusion, flags, scenarios, action を生成。

   **⚠️ 重要**: 各物件は必ず system_prompt を使って1件ずつ AI で分析すること。Python スクリプト、ルールベース処理、一括バッチ処理は**禁止**。get_listings_for_ai の結果が大きくファイルに保存された場合でも、ファイルから読み込んで1件ずつ AI 分析を行うこと。

5. 結果書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'investment_summary', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

---

## ~~Step 2: 画像分析~~ （ルーティン②に移動）

画像分析 & 不要画像クリーンアップはルーティン②（スコアリング & 画像分析）に移動済み。

---

## Step 2: 好みの傾向分析

ユーザーの「いいね」「パス」データから購入傾向を AI で要約し、`buyer_preference_summaries` テーブルに保存する。iOS アプリのダッシュボード「好みの傾向」欄で表示される。

1. いいね/見送りデータ取得:
```sql
-- 注意: user_building_preferences.identity_key はスワイプ時点の 5要素キー
--   (name|layout|area|address|built) だが、listings_feed.identity_key は現行 6要素
--   (…|floor) のため完全一致 JOIN は 0件になる。先頭5要素で突き合わせる。
SELECT ubp.identity_key, ubp.preference,
       lf.name, lf.price_man, lf.area_m2, lf.layout, lf.walk_min,
       lf.built_year, lf.address, lf.direction, lf.station_line,
       lf.floor_position, lf.total_units
FROM user_building_preferences ubp
JOIN listings_feed lf
  ON array_to_string((string_to_array(lf.identity_key, '|'))[1:5], '|') = ubp.identity_key
ORDER BY ubp.preference, ubp.created_at DESC;
```

2. 変更検知: 取得した全行の `identity_key + preference` を結合しハッシュ化。既存の `buyer_preference_summaries.preference_hash` と比較し、同一ならスキップ。

3. いいね5件以上 かつ パス5件以上の場合のみ分析実行。未満の場合はスキップ。

4. 以下のシステムプロンプトで AI 分析:

**システムプロンプト:**
```
あなたは不動産購入のアドバイザーです。
ユーザーがマンション物件を「いいね」「パス」に分類した結果から、
購入希望の傾向を自然な日本語で要約してください。

出力ルール:
- 3〜5行の箇条書き（各行「・」で始める）
- 統計データと具体的な物件例を組み合わせて、読みやすく解説する
- 数値は日本の不動産慣習に従う（万円、㎡、徒歩○分、築○年）
- ユーザーの好みの特徴だけでなく、避けている傾向にも言及する
- 最後に1行、全体的な好みの傾向を一文でまとめる
- 丁寧すぎない自然な文体（です・ます調）
- 出力は箇条書きのテキストのみ。JSON不要
```

**ユーザープロンプト:** いいね/パスそれぞれの物件リスト（名前、価格、面積、間取り、駅距離、築年数、住所、方角）を含める。

5. 結果を保存:
```sql
INSERT INTO buyer_preference_summaries (user_id, summary_lines, liked_count, noped_count, preference_hash, ai_model, ai_calculated_at)
VALUES (
  'default',
  ARRAY['・行1', '・行2', '・行3']::text[],
  <liked_count>,
  <noped_count>,
  '<hash>',
  'claude-sonnet-4-6',
  now()
)
ON CONFLICT (user_id)
DO UPDATE SET
  summary_lines = EXCLUDED.summary_lines,
  liked_count = EXCLUDED.liked_count,
  noped_count = EXCLUDED.noped_count,
  preference_hash = EXCLUDED.preference_hash,
  ai_model = EXCLUDED.ai_model,
  ai_calculated_at = now();
```

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

## Step 4: 通知ドラフト生成

Routine は Slack に直接投稿しない。代わりに `notification_drafts` テーブルに下書きを保存し、
GHA の `slack_notify.py` がボット名義で送信する。

### Step 4a: Daily Brief — スキップ（アプリ表示のみ）

Daily Brief はアプリ（ダッシュボード）で確認するため、Slack 通知はスキップする。

```sql
SELECT skip_notification_draft('slack', 'daily_brief');
```

### Step 4b: Price Alert — お気に入り物件のみ

直近24時間の有意な価格変動を、お気に入り物件に限定して検出:

```sql
SELECT pc.*
FROM get_significant_price_changes(now() - interval '24 hours', 5.0) pc
JOIN user_building_preferences ubp ON ubp.identity_key = (
  SELECT lf.identity_key FROM listings_feed lf WHERE lf.id = pc.listing_id
)
WHERE ubp.preference = 'like';
```

- 結果1件以上: 「💰 *お気に入り物件 価格変動*」+ 各物件の旧価格→新価格（-X%）＋ AI の一言コメント（投資観点で値下げの意味を解説）をメッセージ化して保存:
```sql
SELECT upsert_notification_draft('slack', 'price_alert', '<メッセージ>', '<metadata>'::jsonb);
```

- 結果0件: スキップとして記録:
```sql
SELECT skip_notification_draft('slack', 'price_alert');
```

### Step 4c: 新着 AI ダイジェスト

直近24時間の新着物件を AI が分析し、バイヤー視点でキュレーションした日次ダイジェストを生成する。GHA の raw 新着通知（1日4回）とは別に、1日1回の AI 視点サマリーとして送信される。

1. 直近24時間の新着物件を取得:
```sql
SELECT lf.id, lf.name, lf.address, lf.layout, lf.area_m2, lf.price_man,
       lf.walk_min, lf.station_line, lf.built_year, lf.ownership,
       lf.listing_score, lf.price_fairness_score,
       e.ai_listing_score, e.ai_recommendation_score, e.ai_recommendation_summary
FROM listings_feed lf
LEFT JOIN enrichments e ON e.listing_id = lf.id
WHERE lf.is_active = true
  AND lf.first_seen_at::timestamptz >= now() - interval '24 hours'
ORDER BY COALESCE(e.ai_listing_score, lf.listing_score, 0) DESC;
```

2. バイヤープロファイルと照合し、新着物件を AI で以下のように分類・コメント:

   **メッセージ構成**:
   - 「🏠 *新着 AI ダイジェスト*（{日付}・{件数}件）」ヘッダー
   - 🔥 **必見**（バイヤー条件に合致 + AI スコア4以上）: 物件名・価格・間取り＋ なぜ必見なのか1-2文。お気に入り済み物件との比較があれば言及
   - 👀 **要チェック**（一部条件合致 or AI スコア3）: 物件名・価格・1行コメント
   - 📊 **マーケットメモ**: 「今週の○○エリアは新着X件。先週比+Y件」等、エリア動向を1-2文
   - 該当0件の場合: 「本日の新着で特筆すべき物件はありませんでした」

3. 保存:
```sql
SELECT upsert_notification_draft('slack', 'new_listing_digest', '<メッセージ>', '<metadata>'::jsonb);
```

- 新着0件の場合:
```sql
SELECT skip_notification_draft('slack', 'new_listing_digest');
```

---

## 完了レポート

全ステップ完了後、以下のテンプレートに値を埋めた**マークダウンブロック**をチャットに出力する。
ユーザーはこの出力をそのままログファイルにコピペするため、**余計なテキストを前後に付けず、テンプレート通りの出力のみ**を行うこと。

````markdown
## {YYYY-MM-DD HH:MM} - ルーティン③ 完了レポート

### 実行サマリー

| ステップ | 処理件数 | ステータス |
|---|---|---|
| Step 1: investment_summary | X件（5=X/4=X/3=X/2=X/1=X） | ✅/スキップ |
| Step 2: 好み傾向分析 | — | ✅/スキップ |
| Step 3: buyer_picks | X件抽出 | ✅/スキップ |
| Step 4a: daily_brief | — | skipped |
| Step 4b: price_alert | X件 | pending/skipped |
| Step 4c: new_listing_digest | X件中必見Y件 | pending/skipped |

### Step 1 詳細（上位5件）

| # | listing_id | name | score |
|---|---|---|---|
| 1 | XXXXX | 物件名 | X |
| ... | | | |

### Step 3: buyer_picks 筆頭
- {筆頭物件名と推薦理由1行}

### アラート
- {アラート内容。なければ「なし」}

### エラー
- {エラー内容。なければ「なし」}
````

---

## ファイル操作の禁止

リモート実行環境には GitHub への書き込み権限がないため、以下の操作は**すべて禁止**:
- ログファイルの読み書き・編集
- `git add` / `git commit` / `git push`
- GitHub MCP の `push_files` / `create_branch`

ログファイルの更新はユーザーがローカル環境で行う。

---

## 共通ルール
- **サブエージェント委任禁止**: 全ステップの処理はメインエージェントのコンテキストで実行すること。サブエージェント（Agent ツール）への委任は禁止
- **AI 分析必須**: 各物件は必ず get_active_prompt() で取得した system_prompt を使って1件ずつ AI で分析すること。Python スクリプト、ルールベース処理、一括バッチ処理、Fetch-Then-Ignore パターンは**禁止**
- **Step 4 必須**: Step 1〜3 完了後、必ず Step 4（通知ドラフト生成）を実行すること。Step 4a, 4b, 4c の全てを実行し、該当なしの場合は skip_notification_draft を呼ぶこと。Step 4 をスキップすると Slack 通知が送信されないため、絶対にスキップ禁止
- エラーが発生しても他の物件・ステップの処理は続行する
- 対象が0件のステップはスキップして次へ進む
- Step 4 のエラーは他のステップの結果に影響しない
- 日本語で回答すること
