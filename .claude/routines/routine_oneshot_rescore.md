# ワンショット: プロンプト変更による全件再分析

- スケジュール: ワンショット（手動実行）
- MCP: Supabase（必須）
- 所要時間目安: 2-3時間
- 背景: ai_scoringとinvestment_summaryのプロンプトを改善した。改善内容は、住居適合度を柔軟に評価することと、面積不足で即見送りにしないことである。全物件を新プロンプトで再分析する。

---

## 処理方法の制約（全Step共通）

ルーティン②③と同じ制約を守る。
1. `get_active_prompt(module)`で取得したsystem_promptを**必ず使用**する
2. 各物件を1件ずつAI（自分自身）で分析する
3. Pythonスクリプト、ルールベース処理、Fetch-Then-Ignoreパターンは**すべて禁止**。
4. `prompt_hash`と`version`は`get_active_prompt()`の返り値から取得する

Supabase project_id: `dzhcumdmzskkvusynmyw`

---

## Step 1: ai_scoring全件再分析

### 対象取得

prompt_hashが変わった物件が自動的に対象になる。
```sql
SELECT COUNT(*) FROM get_listings_for_ai('ai_scoring');
```

1回の取得に100件のLIMITがかかる場合は、処理の完了後に再度取得し、0件になるまで繰り返す。

### 処理フロー

1. プロンプト取得
```sql
SELECT * FROM get_active_prompt('ai_scoring');
```

2. バイヤープロファイル取得
```sql
SELECT * FROM buyer_profiles WHERE user_id = '<BUYER_PROFILE_USER_ID>';
```

3. 対象取得
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('ai_scoring');
```

4. 各物件をsystem_promptに従って1件ずつ分析する。出力形式は次のとおり。
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

5. 結果書き戻し
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'ai_scoring', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

6. 対象が0件になるまで、処理フローの手順3から5を繰り返す。

---

## Step 2: investment_summary全件再分析

### 対象取得

```sql
SELECT COUNT(*) FROM get_listings_for_ai('investment_summary');
```

### 処理フロー

1. プロンプト取得
```sql
SELECT * FROM get_active_prompt('investment_summary');
```

2. バイヤープロファイルを取得する（Step 1と同じ）

3. 対象取得
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('investment_summary');
```

4. 各物件をsystem_promptに従って1件ずつ分析する。

面積不足だけで即スコア1にしない。子ども2人のシナリオと短期の住み替え戦略も含めて、柔軟に評価する。

5. 結果書き戻し
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'investment_summary', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

6. 対象が0件になるまで繰り返す。

---

## 完了レポート

```markdown
## プロンプト変更後の全件再分析 完了レポート

### 実行サマリー

| ステップ | 処理件数 | ステータス |
|---|---|---|
| Step 1: ai_scoring | X件（平均XX点、S:X A:X B:X C:X D:X） | ✅ |
| Step 2: investment_summary | X件（スコア分布 5:X 4:X 3:X 2:X 1:X） | ✅ |

### スコア変化の傾向
- listing_score: 旧平均XX → 新平均XX
- recommendation: 旧分布 vs 新分布
- 面積65㎡未満物件のスコア変化の特徴

### アラート
- {アラート内容。なければ「なし」}
```

---

## ファイル操作の禁止

リモート実行環境のため、次の操作は禁止する。
- ログファイルの読み書き
- git操作
- Pythonスクリプト実行

## 共通ルール
- サブエージェント委任禁止
- AI分析必須（ルールベース処理は禁止）
- エラーが発生しても、他の物件の処理は続行する
- 日本語で回答する
