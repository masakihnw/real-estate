# ルーティン②: スコアリング & 画像分析

- **スケジュール**: 毎日 JST 4:00（1回/日）
- **MCP**: Supabase（必須）
- **所要時間目安**: 30-40分
- **前提**: ルーティン①（JST 3:00）が完了済みであること

---

## 概要

ルーティン①でクレンジングされたデータに対して、AI スコアリング（5軸評価 + グレード付与）と画像分析を行う。
バイヤープロファイルを動的に参照し、物件の総合適合度を評価する。

Supabase project_id: `dzhcumdmzskkvusynmyw`
全ての SQL は Supabase MCP の `execute_sql` で実行すること。

---

## ⛔ 処理方法の制約（全 Step 共通）

全ての AI 分析ステップは、以下を遵守すること:
1. `get_active_prompt(module)` で取得した system_prompt を**必ず使用**する
2. 各物件を **1件ずつ AI（自分自身）で分析**する — system_prompt の指示に従い、JSON を生成する
3. 以下は**すべて禁止**:
   - Python スクリプトの作成・実行（`python3 << 'EOF'` 等）
   - ルールベース処理（キーワードマッチング、重み付け計算式、if/else 分岐ロジック）
   - Bash コマンドでのデータ加工・スコア計算
   - 取得した system_prompt を無視して独自ロジックで処理（Fetch-Then-Ignore パターン）
4. upsert_ai_enrichment の `prompt_hash` と `version` は `get_active_prompt()` の返り値から取得すること（ハードコード禁止）

---

## Step 0: ヘルスチェック参照 & ルーティン①完了確認

```sql
SELECT * FROM get_latest_health_check();
```

- check_date が本日でない場合、ルーティン①が未完了の可能性があるため警告を報告（処理は続行）
- 結果が0件の場合はスキップして Step 1 へ進む

---

## Step 1: AI 動的スコアリング（5軸評価 + グレード）

バイヤープロファイルと物件データを照合し、5軸均等加重（各20%）で総合適合スコアとグレードを算出する。

### 評価軸
1. **予算適合度** (20%): FPシナリオとの整合性、金利耐性
2. **住居適合度** (20%): 面積・間取り × 家族計画
3. **立地総合** (20%): 通勤時間 + 駅距離 + エリア利便性
4. **建物・管理品質** (20%): 築年数、総戸数、管理状態
5. **出口・流動性** (20%): 売却しやすさ、残債割れリスク、価格妥当性

### 手順

1. プロンプト取得:
```sql
SELECT * FROM get_active_prompt('ai_scoring');
```

2. バイヤープロファイル取得:
```sql
SELECT * FROM buyer_profiles WHERE user_id = '[USER_ID]';
```
→ 全フィールドを日本語テキストにフォーマット。user_prompt_template の `{buyer_profile}` に代入。

3. 対象取得:
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('ai_scoring');
```

→ 同一 normalized_name の物件は DISTINCT ON で重複排除済み。
→ prompt_hash が変更されていない物件はスキップ。
→ 高スコア物件（≥65 = Grade A/S）は rescore_interval（1日）経過で自動的に再分析対象。

4. 各物件について system_prompt に従い分析。user_prompt_template の `{buyer_profile}` にバイヤープロファイル、`{listing_data}` に物件データを代入。

   出力形式:
   ```json
   {
     "listing_score": 75,
     "price_fairness_score": 62,
     "asset_grade": "A",
     "grade_override_reason": null,
     "reasoning": {
       "budget": {"score": 90, "note": "..."},
       "living": {"score": 70, "note": "..."},
       "location": {"score": 80, "note": "..."},
       "building": {"score": 75, "note": "..."},
       "exit": {"score": 72, "note": "..."},
       "strengths": ["..."],
       "weaknesses": ["..."]
     }
   }
   ```

   **⚠️ 重要**: 各物件は必ず system_prompt を使って1件ずつ AI で分析すること。

5. 結果書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'ai_scoring', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

対象がなければスキップして Step 2 へ。

---

## Step 2: 画像分析 & 不要画像クリーンアップ

**方針**: suumo_images の `label` フィールドを使ったラベルベース分類を行う。分類後、不要画像は DB から削除する。

### Step 2a: 画像分類

1. プロンプト取得:
```sql
SELECT * FROM get_active_prompt('image_analyzer');
```

2. 対象取得:
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('image_analyzer');
```

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

4. 結果書き戻し:
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'image_analyzer', '<画像結果配列>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

### Step 2b: 不要画像の削除

Step 2a 完了後に実行:
```sql
SELECT * FROM batch_cleanup_junk_images();
```

対象がなければスキップ。

---

## 完了レポート

````markdown
## {YYYY-MM-DD} - ルーティン② 完了レポート

### 実行サマリー

| ステップ | 処理件数 | ステータス |
|---|---|---|
| Step 0: ヘルスチェック | — | ✅/⚠️ |
| Step 1: AIスコアリング | X件（平均XX点、S:X A:X B:X C:X D:X） | ✅/スキップ |
| Step 2: 画像分析 | X件（junk削除Y件） | ✅/スキップ |

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

---

## 共通ルール
- **サブエージェント委任禁止**: 全ステップの処理はメインエージェントのコンテキストで実行すること
- **AI 分析必須**: Step 1 の各物件は必ず get_active_prompt() で取得した system_prompt を使って1件ずつ AI で分析すること。Python スクリプト、ルールベース処理、一括バッチ処理、Fetch-Then-Ignore パターンは**禁止**
- エラーが発生しても他の物件・ステップの処理は続行する
- 対象が0件のステップはスキップして次へ進む
- 日本語で回答すること
