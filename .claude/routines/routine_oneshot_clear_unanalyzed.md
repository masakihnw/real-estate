# ワンショット: AI未分析物件の一括解消（並行シャード対応）

- **スケジュール**: ワンショット（手動実行・複数セッション並行可）
- **MCP**: Supabase（必須）
- **背景**: 購入戦略の3層化に伴い ai_prompts を更新（investment_summary v6 / ai_scoring v7、2026-06-11適用）。
  prompt_hash が変わったため全アクティブ物件が再分析対象になった。
  通常の日次ルーティンの処理上限（50/100件/回）では消化に数週間かかるため、ワンショットで処理しきる。
- **規模**（2026-06-11 時点）: text_enricher 15件 / ai_scoring 883件 / investment_summary 1,188件。
  1セッションでは処理しきれないため、**シャード分割して複数セッションで並行実行**する。
- **推奨**: `SHARD_COUNT = 8`（1シャードあたり約260件 ≒ investment_summary 150件 + ai_scoring 110件）。
  セッション数を減らす場合も1シャード300件超にしない（コンテキスト枯渇防止）。

---

## 🔀 シャード設定（このセッションの担当範囲）

このセッションが担当するシャードを以下で指定する。**起動時にユーザーが指定する**:

```
SHARD_COUNT = 8   ← 同時に起動する並行セッションの総数（N）
SHARD_INDEX = 0   ← このセッションの担当番号（0 〜 N-1）
```

> 例: 4セッション並行なら、それぞれ `SHARD_INDEX = 0, 1, 2, 3` で起動する。
> 各セッションは `listing_id % SHARD_COUNT = SHARD_INDEX` の物件**のみ**を処理するため、
> セッション間で物件が重複せず、衝突しない。

**⚠️ 全 SQL の対象取得クエリに必ず `WHERE listing_id % <SHARD_COUNT> = <SHARD_INDEX>` を付けること。**
このフィルタを外すと他セッションと二重処理になる。

---

## ⛔ 処理方法の制約（全 Step 共通）

ルーティン②③と同じ制約:
1. `get_active_prompt(module)` で取得した system_prompt を**必ず使用**する
2. 各物件を **1件ずつ AI（自分自身）で分析**する
3. 以下は**すべて禁止**:
   - Python スクリプトの作成・実行
   - ルールベース処理（キーワードマッチング、計算式、if/else 分岐）
   - Bash でのデータ加工・スコア計算
   - サブエージェント（Agent ツール）への委任
   - Fetch-Then-Ignore パターン（取得した system_prompt を無視）
4. `upsert_ai_enrichment` の `prompt_hash` と `version` は `get_active_prompt()` の返り値から取得

Supabase project_id: `dzhcumdmzskkvusynmyw`
全ての SQL は Supabase MCP の `execute_sql` で実行すること。

---

## 📐 対象取得クエリの共通パターン

`get_listings_for_ai` は `max_items_per_run` で内部 LIMIT される。全バックログを見えるようにするため
**第2引数で上限を引き上げ**、外側で**シャードフィルタ + チャンク LIMIT**をかける:

```sql
SELECT listing_id, listing_data
FROM get_listings_for_ai('<module>', '{"max_items_per_run":100000}'::jsonb)
WHERE listing_id % <SHARD_COUNT> = <SHARD_INDEX>
ORDER BY listing_id
LIMIT 20;
```

- 処理済み物件は次回クエリで自動的に除外される（extracted_features / ai_listing_score 等がセットされるため）
- よって **0件になるまでこのクエリ→分析→書き戻しを繰り返す**だけで、シャード内全件を消化できる
- 1回20件のチャンクにすることでコンテキストを管理しやすくする

**このセッションは途中で中断しても安全**: 再開時に同じクエリを叩けば、未処理の残りだけが返る。

---

## Step 1: text_enricher（このシャード分）

ai_scoring / investment_summary が参照する `extracted_features` を生成するため**最初に処理**する。

```sql
SELECT prompt_hash, version, system_prompt, user_prompt_template
FROM get_active_prompt('text_enricher');
```

対象取得（共通パターン、module = `text_enricher`）→ 各物件を system_prompt に従い1件ずつ分析。

書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'text_enricher', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

シャード分が 0 件になるまで繰り返す。

---

## Step 2: ai_scoring（このシャード分）

Step 1（このシャード分）完了後に実行。

```sql
SELECT * FROM get_active_prompt('ai_scoring');
SELECT * FROM buyer_profiles WHERE user_id = '[USER_ID]';
```

対象取得（共通パターン、module = `ai_scoring`）→ 各物件を1件ずつ分析。
user_prompt_template の `{buyer_profile}` にバイヤープロファイル、`{listing_data}` に物件データを代入。

出力形式:
```json
{
  "listing_score": 75,
  "price_fairness_score": 62,
  "asset_grade": "A",
  "grade_override_reason": null,
  "reasoning": {
    "budget": {"score": 90, "note": "..."},
    "living": {"score": 70, "note": "子2人なら小学校卒業まで10年対応可。3人だと就学前に限界"},
    "location": {"score": 80, "note": "..."},
    "building": {"score": 75, "note": "..."},
    "exit": {"score": 72, "note": "..."},
    "strengths": ["..."],
    "weaknesses": ["..."]
  }
}
```

**⚠️ 住居適合度のnoteには必ず「子ども何人なら何年住めるか」を含めること。**

書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'ai_scoring', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

シャード分が 0 件になるまで繰り返す。

---

## Step 3: investment_summary（このシャード分）

Step 2（このシャード分）完了後に実行。

```sql
SELECT * FROM get_active_prompt('investment_summary');
```

バイヤープロファイルは Step 2 で取得したものを再利用。
対象取得（共通パターン、module = `investment_summary`）→ 各物件を1件ずつ分析。
system_prompt に従い JSON で `score, conclusion, flags, scenarios, action` を生成。

**⚠️ 面積不足だけで即スコア1にしないこと。子ども2人シナリオ、短期住み替え戦略も含めて柔軟に評価。**

書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'investment_summary', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

シャード分が 0 件になるまで繰り返す。

---

## Step 4: このシャードの完了確認

3モジュールとも、このシャード分の対象取得クエリが 0 件になったことを確認する:

```sql
SELECT 'text_enricher' AS module, COUNT(*) AS remaining
FROM get_listings_for_ai('text_enricher', '{"max_items_per_run":100000}'::jsonb)
WHERE listing_id % <SHARD_COUNT> = <SHARD_INDEX>
UNION ALL
SELECT 'ai_scoring', COUNT(*)
FROM get_listings_for_ai('ai_scoring', '{"max_items_per_run":100000}'::jsonb)
WHERE listing_id % <SHARD_COUNT> = <SHARD_INDEX>
UNION ALL
SELECT 'investment_summary', COUNT(*)
FROM get_listings_for_ai('investment_summary', '{"max_items_per_run":100000}'::jsonb)
WHERE listing_id % <SHARD_COUNT> = <SHARD_INDEX>;
```

---

## 完了レポート

````markdown
## {YYYY-MM-DD HH:MM} - ワンショット未分析解消 完了レポート（シャード {SHARD_INDEX}/{SHARD_COUNT}）

### 実行サマリー

| ステップ | 処理件数 | このシャードの残件数 | ステータス |
|---|---|---|---|
| Step 1: text_enricher | X | 0 | ✅ |
| Step 2: ai_scoring | X | 0 | ✅ |
| Step 3: investment_summary | X | 0 | ✅ |

### スコア分布（このシャード分）
- **ai_scoring**: S:X / A:X / B:X / C:X / D:X
- **investment_summary**: 5:X / 4:X / 3:X / 2:X / 1:X

### 注目物件（このシャードの ai_listing_score Top 3）
| listing_id | name | score |
|---|---|---|
| XXXXX | 物件名 | XX |

### アラート / エラー
- {内容。なければ「なし」}
````

---

## ファイル操作の禁止

リモート実行環境のため以下は禁止:
- ログファイルの読み書き・編集
- `git add` / `git commit` / `git push`
- GitHub MCP の `push_files` / `create_branch`

---

## 共通ルール

- **シャードフィルタ必須**: 全対象取得クエリに `WHERE listing_id % <SHARD_COUNT> = <SHARD_INDEX>` を付ける
- **サブエージェント委任禁止**: 全ステップの処理はメインエージェントのコンテキストで実行
- **AI 分析必須**: ルールベース処理・Python スクリプト・一括バッチ処理は禁止
- **順序遵守**: 自シャード内で Step 1 → 2 → 3 の順（text_enricher の結果を後段が参照するため）
- 中断しても安全。再開時は同じクエリで残りが返る
- エラーが発生しても他の物件・ステップの処理は続行する
- 日本語で回答すること
