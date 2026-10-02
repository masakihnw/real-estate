# ワンショット: AI未分析物件の一括解消（並行シャード対応）

- スケジュール: ワンショット（手動実行・複数セッション並行可）
- MCP: Supabase（必須）
- 背景: 購入戦略を3層に分けたためai_promptsを更新した（investment_summary v6、ai_scoring v7、2026-06-11適用）。
  prompt_hashが変わり、全アクティブ物件が再分析の対象になった。
  通常の日次ルーティンは1回の処理上限が50件と100件で、消化に数週間かかる。そこで、このワンショットで全件を処理する。
- 規模（2026-06-11時点）: text_enricher 15件 / ai_scoring 883件 / investment_summary 1,188件。
  1セッションでは処理しきれないので、シャードに分割して複数セッションで並行実行する。
- 推奨: `SHARD_COUNT = 8`（1シャードあたり約260件 ≒ investment_summary 150件 + ai_scoring 110件）。
  セッション数を減らす場合も、コンテキストを使い切らないよう、1シャードを300件以内にする。

---

## シャード設定（このセッションの担当範囲）

このセッションが担当するシャードを次の値で指定する。起動時にユーザーが指定する。

```
SHARD_COUNT = 8   ← 同時に起動する並行セッションの総数（N）
SHARD_INDEX = 0   ← このセッションの担当番号（0 〜 N-1）
```

> 例: 4セッション並行なら、それぞれ`SHARD_INDEX = 0, 1, 2, 3`で起動する。
> 各セッションは`listing_id % SHARD_COUNT = SHARD_INDEX`の物件だけを処理する。
> そのため、セッション間で物件が重複せず、衝突しない。

全SQLの対象取得クエリに、必ず`WHERE listing_id % <SHARD_COUNT> = <SHARD_INDEX>`を付ける。
このフィルタを外すと、他セッションと二重に処理する。

---

## 処理方法の制約（全Step共通）

ルーティン②③と同じ制約を守る。
1. `get_active_prompt(module)`で取得したsystem_promptを**必ず使用**する
2. 各物件を1件ずつAI（自分自身）で分析し、system_promptの指示に従ってJSONを生成する
3. 以下は**すべて禁止**。
   - Pythonスクリプトの作成・実行（`python3 << 'EOF'`等）
   - ルールベース処理（キーワードマッチング、重み付け計算式、if/else分岐ロジック）
   - Bashコマンドでのデータ加工・スコア計算
   - 取得したsystem_promptを無視して独自ロジックで処理する（Fetch-Then-Ignoreパターン）
   - サブエージェント（Agentツール）への委任
4. upsert_ai_enrichmentの`prompt_hash`と`version`は`get_active_prompt()`の返り値から取得する（ハードコード禁止）

Supabase project_id: `dzhcumdmzskkvusynmyw`
全てのSQLはSupabase MCPの`execute_sql`で実行する。

---

## 対象取得クエリの共通パターン

`get_listings_for_ai`は`max_items_per_run`で内部のLIMITがかかる。未処理の全件を取得するため、
第2引数で上限を引き上げ、外側でシャードフィルタとチャンクのLIMITをかける。

```sql
SELECT listing_id, listing_data
FROM get_listings_for_ai('<module>', '{"max_items_per_run":100000}'::jsonb)
WHERE listing_id % <SHARD_COUNT> = <SHARD_INDEX>
ORDER BY listing_id
LIMIT 20;
```

- 処理済みの物件は、extracted_featuresやai_listing_scoreなどがセットされるので、次回のクエリから自動的に除外される
- したがって、0件になるまで「このクエリ、分析、書き戻し」を繰り返せば、シャード内の全件を処理できる
- 1回を20件のチャンクにして、コンテキストの消費を抑える

このセッションは途中で中断しても安全である。再開時に同じクエリを実行すれば、未処理の残りだけが返る。

---

## Step 1: text_enricher（このシャード分）

ai_scoringとinvestment_summaryは`extracted_features`を参照する。そのため、text_enricherを最初に処理する。

```sql
SELECT prompt_hash, version, system_prompt, user_prompt_template
FROM get_active_prompt('text_enricher');
```

対象取得（共通パターン、module = `text_enricher`）のあと、各物件をsystem_promptに従って1件ずつ分析する。

書き戻し
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'text_enricher', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

シャード分が0件になるまで繰り返す。

---

## Step 2: ai_scoring（このシャード分）

Step 1（このシャード分）の完了後に実行する。

```sql
SELECT * FROM get_active_prompt('ai_scoring');
SELECT * FROM buyer_profiles WHERE user_id = '[USER_ID]';
```

対象取得（共通パターン、module = `ai_scoring`）のあと、各物件を1件ずつ分析する。
user_prompt_templateの`{buyer_profile}`にバイヤープロファイル、`{listing_data}`に物件データを代入する。

出力形式
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

住居適合度のnoteには、必ず「子ども何人なら何年住めるか」を含める。

書き戻し
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'ai_scoring', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

シャード分が0件になるまで繰り返す。

---

## Step 3: investment_summary（このシャード分）

Step 2（このシャード分）の完了後に実行する。

```sql
SELECT * FROM get_active_prompt('investment_summary');
```

バイヤープロファイルは、Step 2で取得したものを再利用する。
対象取得（共通パターン、module = `investment_summary`）のあと、各物件を1件ずつ分析する。
system_promptに従い、JSONで`score, conclusion, flags, scenarios, action`を生成する。

面積不足だけで即スコア1にしない。子ども2人のシナリオと短期の住み替え戦略も含めて、柔軟に評価する。

書き戻し
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'investment_summary', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

シャード分が0件になるまで繰り返す。

---

## Step 4: このシャードの完了確認

3モジュールとも、このシャード分の対象取得クエリが0件になったことを確認する。

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

リモート実行環境のため、次の操作は禁止する。
- ログファイルの読み書き・編集
- `git add` / `git commit` / `git push`
- GitHub MCPの`push_files` / `create_branch`

---

## 共通ルール

- シャードフィルタ必須: 全対象取得クエリに`WHERE listing_id % <SHARD_COUNT> = <SHARD_INDEX>`を付ける
- サブエージェント委任禁止: 全ステップの処理をメインエージェントのコンテキストで実行する
- AI分析必須: ルールベース処理、Pythonスクリプト、一括バッチ処理は禁止
- 順序遵守: 自シャード内でStep 1、2、3の順に実行する（後段がtext_enricherの結果を参照するため）
- 中断しても安全。再開時は同じクエリで残りが返る
- エラーが発生しても、他の物件とステップの処理は続行する
- 日本語で回答する
