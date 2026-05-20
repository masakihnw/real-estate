# ルーティン①: データ準備 & スコアリング

- **スケジュール**: 毎日 JST 3:00（1回/日）
- **MCP**: Supabase（必須）
- **所要時間目安**: 15-30分

---

## 概要

不動産物件データのクレンジング・エンリッチメントを行う。
後続のルーティン②（AI分析 & ピック）が依存するため、先に実行する。

Supabase project_id: `dzhcumdmzskkvusynmyw`
全ての SQL は Supabase MCP の `execute_sql` で実行すること。

---

## ⛔ 処理方法の制約（全 Step 共通）

全ての AI 分析ステップ（Step 1-3）は、以下を遵守すること:
1. `get_active_prompt(module)` で取得した system_prompt を**必ず使用**する
2. 各物件を **1件ずつ AI（自分自身）で分析**する — system_prompt の指示に従い、JSON を生成する
3. 以下は**すべて禁止**:
   - Python スクリプトの作成・実行（`python3 << 'EOF'` 等）
   - ルールベース処理（キーワードマッチング、重み付け計算式、if/else 分岐ロジック）
   - Bash コマンドでのデータ加工・スコア計算
   - 取得した system_prompt を無視して独自ロジックで処理（Fetch-Then-Ignore パターン）
4. upsert_ai_enrichment の `prompt_hash` と `version` は `get_active_prompt()` の返り値から取得すること（ハードコード禁止）

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
- 結果が0件（Routine 3 未実行）の場合はスキップして Step 0.5 へ進む

---

## Step 0.5: データ品質クリーンアップ（AI名前検証）

スクレイパーが取り込んだゴミデータ（ページタイトル、説明文、空名前）を検出・除去し、
normalized_name の品質を維持する。Phase A は SQL 自動処理、Phase B は AI 判定。

### Phase A: 自動クリーンアップ（SQL のみ）

明らかなゴミを一括削除する。AI 判定不要。

```sql
-- A-1: ページタイトル（SUUMOの一覧ページがそのまま取り込まれたもの）
DELETE FROM listings
WHERE normalized_name LIKE '%物件一覧%'
RETURNING id;

-- A-2: 空名前
DELETE FROM listings
WHERE name = '' OR normalized_name = ''
RETURNING id;
```

→ 削除件数を報告に記録する。0件でも Phase B に進む。

### Phase B: AI 名前品質チェック

正規表現では判定しきれない疑わしいレコードを AI で検証する。

1. 対象取得:
```sql
SELECT l.id, l.name, l.normalized_name, l.address, l.layout, l.area_m2,
       l.built_year, l.identity_key, l.is_active
FROM listings l
WHERE l.is_active = true
AND (
  -- normalized_name が identity_key の名前部分と不一致
  l.normalized_name != SPLIT_PART(l.identity_key, '|', 1)
  -- 物件名に不自然なパターンが含まれる
  OR l.normalized_name ~ '(ペット可|即入居|リフォーム|リノベ|角部屋|オーナーチェンジ|値下げ|新規分譲)'
  OR l.normalized_name ~ '^[東西南北]+向き'
  OR l.normalized_name ~ '\d+(\.\d+)?平米'
  OR l.normalized_name ~ 'LDK住戸$'
  OR LENGTH(l.normalized_name) <= 2
)
ORDER BY l.created_at DESC
LIMIT 30;
```

2. 各レコードを AI（自分自身）で判定する。以下の観点で判断:

   - **name** と **normalized_name** は正当な日本のマンション・物件名か？
   - 説明文・特徴タグ・ページタイトルが物件名になっていないか？
   - 同一住所・同一スペックの正しい名前のレコードが既に存在しないか？

3. 判定結果に応じたアクション:

   | 判定 | アクション |
   |---|---|
   | **ゴミ（物件名ではない）** | `DELETE FROM listings WHERE id = <id>` |
   | **修正可能（正しい名前を推定できる）** | `UPDATE listings SET normalized_name = '<正しい名前>', identity_key = '<修正済みkey>' WHERE id = <id>` |
   | **正しいレコードにマージ可能** | マージ先の alt_urls に URL を追加し、当該レコードを `DELETE` |
   | **判断不能** | `pipeline_issues` に記録して手動確認待ち |

   マージ先の確認:
   ```sql
   SELECT id, name, normalized_name, identity_key
   FROM listings
   WHERE address LIKE '%<同一住所パターン>%'
     AND area_m2 = <同一面積>
     AND layout = '<同一間取り>'
     AND id != <対象id>
   ORDER BY is_active DESC, created_at ASC
   LIMIT 5;
   ```

4. 判断不能のレコードを pipeline_issues に記録:
   ```sql
   INSERT INTO pipeline_issues (source, severity, message, details, created_at)
   VALUES ('routine_1_name_quality', 'medium',
           '物件名の品質チェックで判断不能: <normalized_name> (ID: <id>)',
           '{"listing_id": <id>, "name": "<name>", "normalized_name": "<normalized_name>"}'::jsonb,
           NOW())
   ON CONFLICT DO NOTHING;
   ```

対象が0件ならスキップして Step 1 へ。

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

   **⚠️ 重要**: 各物件は必ず system_prompt を使って1件ずつ AI で分析すること。Python スクリプト、ルールベース処理、キーワードマッチングは**禁止**。

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
→ ただし高スコア物件（ai_listing_score >= rescore_min_score、デフォルト65 = Grade A/S）は rescore_interval（デフォルト1日）経過で自動的に再分析対象になる。これにより環境変化（バイヤープロファイル・市況・通勤情報等）が推奨度に反映される。

3. 各物件について system_prompt に従い、listing_data 全体を渡して総合適合スコア listing_score (0-100) と price_fairness_score (0-100) を算出。system_prompt にはバイヤープロファイル（家族構成・予算・通勤・間取り要件等）が組み込まれており、「この家族にとっての適合度」を6軸（通勤・予算・間取り・立地・建物品質・資産性）で評価する。結果は listing_score に直接書き込まれ iOS アプリのソート順に反映される。

   **⚠️ 重要**: 各物件は必ず system_prompt を使って1件ずつ AI で分析すること。Python スクリプト、ルールベース処理、重み付けスコア計算式は**禁止**。

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

全ステップ完了後、以下のテンプレートに値を埋めた**マークダウンブロック**をチャットに出力する。
ユーザーはこの出力をそのままログファイルにコピペするため、**余計なテキストを前後に付けず、テンプレート通りの出力のみ**を行うこと。

````markdown
## {YYYY-MM-DD} - ルーティン① 完了レポート

### 実行サマリー

| ステップ | 処理件数 | ステータス |
|---|---|---|
| Step 0: ヘルスチェック | — | ✅/⚠️ |
| Step 0.5: データ品質 | 自動削除X件、AI検証Y件（修正Z件、削除W件） | ✅/スキップ |
| Step 1: 重複排除 | X件（merge Y件、flag Z件） | ✅/スキップ |
| Step 2: テキスト特徴抽出 | X件 | ✅/スキップ |
| Step 3: AIスコアリング | X件（平均XX点） | ✅/スキップ |
| Step 4: 通勤時間更新 | X件（ヒットY件、parse_failed Z件） | ✅/スキップ |

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
- **AI 分析必須**: Step 1-3 の各物件は必ず get_active_prompt() で取得した system_prompt を使って1件ずつ AI で分析すること。Python スクリプト、ルールベース処理、一括バッチ処理、Fetch-Then-Ignore パターンは**禁止**
- エラーが発生しても他の物件・ステップの処理は続行する
- 対象が0件のステップはスキップして次へ進む
- 日本語で回答すること
