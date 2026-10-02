# ルーティン①: データクレンジング

- スケジュール: 毎日JST 3:00（1回/日）
- MCP: Supabase（必須）
- 所要時間目安: 15-25分

---

## 概要

不動産物件データのクレンジングとエンリッチメントを行う。
後続のルーティン②（スコアリング & 画像分析）がこの結果に依存するので、先に実行する。

ほかのルーティンやワークフローへ移した処理は次のとおり。
- AIスコアリング（ai_scoringモジュール）はバイヤープロファイルを参照する。そのため、ルーティン②のStep 1で実行する
- クラウドコンテナからhomes.co.jpへ接続できない。そのため、HOME'S画像の取得はGitHub Actionsの`backfill-homes-images`ワークフローへ移した。このワークフローは現在GitHub側で無効（`disabled_manually`）である。CIパイプライン（`run_enrich.sh` Track G）も、新着物件の画像をローカルとGHA環境で自動取得する

Supabase project_id: `dzhcumdmzskkvusynmyw`
全てのSQLはSupabase MCPの`execute_sql`で実行する。

---

## 処理方法の制約（全Step共通）

AI分析ステップ（Step 1-2）は、次の制約を守る。
1. `get_active_prompt(module)`で取得したsystem_promptを**必ず使用**する
2. 各物件を1件ずつAI（自分自身）で分析し、system_promptの指示に従ってJSONを生成する
3. 以下は**すべて禁止**。
   - Pythonスクリプトの作成・実行（`python3 << 'EOF'`等）
   - ルールベース処理（キーワードマッチング、重み付け計算式、if/else分岐ロジック）
   - Bashコマンドでのデータ加工・スコア計算
   - 取得したsystem_promptを無視して独自ロジックで処理する（Fetch-Then-Ignoreパターン）
4. upsert_ai_enrichmentの`prompt_hash`と`version`は`get_active_prompt()`の返り値から取得する（ハードコード禁止）

---

## Step 0: ヘルスチェック参照（自律修正）

直近のヘルスチェック結果を確認し、ルーティン①の処理に影響するアラートがあれば対応する。

```sql
SELECT * FROM get_latest_health_check();
```

確認項目と対応

| alerts.source | 該当チェック | 対応アクション |
|---|---|---|
| `data_quality` / `duplicate_active` | 重複アクティブ物件あり | Step 1のdedupで優先的に処理されるので、件数を確認する |
| `freshness` / `no_enrichment_48h` | 48h以上エンリッチメントなし | Step 2、Step 3、ルーティン②で該当物件が処理されるか確認する |
| `freshness` / `stale_ai_7d` | AI分析が7日以上古い | ルーティン②のStep 1で再スコアリング対象に含まれているか確認する |
| `coverage` / 基準未満フィールド | エンリッチメント不足 | 該当Stepで処理漏れがないか確認する |

- check_dateが2日以上前の場合、ルーティン④が未実行の可能性があるので警告を報告する（処理は続行）
- 結果が0件（ルーティン④未実行）の場合はスキップしてStep 0.5へ進む

---

## Step 0.5: データ品質クリーンアップ（AI名前検証）

スクレイパーが取り込んだ不要データ（ページタイトル、説明文、空名前）を検出して除去する。
normalized_nameの品質を維持するのが目的である。Phase AはSQLで自動処理し、Phase BはAIが判定する。

### Phase A: 自動クリーンアップ（SQLのみ）

明らかな不要データを一括削除する。AI判定は要らない。

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

削除件数を報告に記録する。0件でもPhase Bに進む。

### Phase B: AI名前品質チェック

正規表現では判定しきれない疑わしいレコードをAIで検証する。

1. 対象取得
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
  -- name にプロモーション文言（×区切りタグ・【】内修飾語等）が含まれ、normalized_name と異なる
  -- 「テラス加賀　【リノベ】」のように差分が小さいケースも拾うため文字数差の閾値（+10）は撤廃し、
  -- 販促マーカーの有無 + normalized_name が非空であることでゲートする
  OR (
    l.name ~ '[×【】◆★☆]'
    AND l.normalized_name != ''
    AND l.name != l.normalized_name
    AND LENGTH(l.name) > LENGTH(l.normalized_name)
  )
)
ORDER BY l.created_at DESC
LIMIT 30;
```

2. 各レコードをAI（自分自身）で判定する。以下の観点で判断。

   - nameとnormalized_nameは正当な日本のマンション・物件名か？
   - 説明文・特徴タグ・ページタイトルが物件名になっていないか？
   - 同一住所・同一スペックの正しい名前のレコードが既に存在しないか？
   - `name`にプロモーション文言が含まれ、`normalized_name`と大きく異なる場合は、`name`を`normalized_name`の値で上書きする（`UPDATE listings SET name = normalized_name WHERE id = <id>`）。プロモーション文言とは、ペット可×南向き等の×区切りタグと、【】内の修飾語を指す

3. 判定結果に応じたアクション。

   | 判定 | アクション |
   |---|---|
   | 不要データ（物件名ではない） | `DELETE FROM listings WHERE id = <id>` |
   | 修正可能（正しい名前を推定できる） | `UPDATE listings SET normalized_name = '<正しい名前>', identity_key = '<修正済みkey>' WHERE id = <id>` |
   | 正しいレコードにマージ可能 | マージ先のalt_urlsにURLを追加し、当該レコードを`DELETE` |
   | 判断不能 | `pipeline_issues`に記録して手動確認待ち |

   マージ先の確認
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

4. 判断不能のレコードを`pipeline_issues`に記録する。

   必ず`upsert_pipeline_issue()`を使い、issue_keyは`name_quality_{id}`で一意にする。
   旧版の`INSERT INTO pipeline_issues (source, ...)`は、現行スキーマに存在しない列を参照する書き方だった。
   この書き方では、実行ごとに`r1_name_quality_*`と`routine_1_name_quality_*`のように異なるキーで重複登録され、
   同一物件が複数のキーで残っていた。
   `name_quality_{id}`に統一すると、同一物件は1つのキーで管理され、再検出時にupsertされる。

   ```sql
   SELECT upsert_pipeline_issue(
     'name_quality_' || <id>,          -- issue_key（物件IDで一意化）
     'medium',                          -- severity
     'data_quality',                    -- category
     '物件名の品質低下（手動確認）',    -- title
     '物件名の品質チェックで判断不能: <normalized_name> (ID: <id>)',  -- description
     jsonb_build_object('listing_id', <id>, 'name', '<name>', 'normalized_name', '<normalized_name>'),
     '真の建物名を住所・築年から特定し normalized_name/identity_key を補正。特定不能なら wont_fix。',
     'manual'                           -- fix_type
   );
   ```

対象が0件ならスキップしてStep 0.7へ。

---

## Step 0.7: AIファジー重複検出

Step 1（セマンティック重複排除）は`normalized_name`の完全一致で候補を絞り込む。
そのため、ダッシュの異体字（ー と -）や細かい表記揺れを検出できない。
次のような違いがあると、同一マンション・同一部屋が別物件として扱われる。

- 英語とカタカナの表記差（`BrilliaCity西早稲田`と`ブリリアシティ西早稲田`）
- 三点リーダーの残存（`AQUAVISTA...`）
- 間取り表記の揺れ（`2SLDK`と`2LDK+S`）

その結果、Slack通知が誤って「入れ替え」と報告する。
このステップでは、より広い候補をAIが判定し、その場で修正する。

1. 候補ペア取得
```sql
SELECT l1.id AS id_a, l2.id AS id_b,
       l1.name AS name_a, l2.name AS name_b,
       l1.normalized_name AS norm_a, l2.normalized_name AS norm_b,
       l1.layout AS layout_a, l2.layout AS layout_b,
       l1.area_m2 AS area_a, l2.area_m2 AS area_b,
       l1.floor_position AS floor_a, l2.floor_position AS floor_b,
       l1.built_year AS built_a, l2.built_year AS built_b,
       l1.address AS addr_a, l2.address AS addr_b,
       (SELECT ls.price_man FROM listing_sources ls WHERE ls.listing_id = l1.id AND ls.is_active ORDER BY ls.last_seen_at DESC LIMIT 1) AS price_a,
       (SELECT ls.price_man FROM listing_sources ls WHERE ls.listing_id = l2.id AND ls.is_active ORDER BY ls.last_seen_at DESC LIMIT 1) AS price_b
FROM listings l1
JOIN listings l2
  ON l1.id < l2.id
  AND l1.is_active AND l2.is_active
  AND l1.built_year = l2.built_year
  AND l1.normalized_name != l2.normalized_name
  AND (
    -- (A) ダッシュ系文字を統一して比較（同一間取り・近似面積が前提）
    -- 長音記号の異体字（ー ｰ － ‐ ‑ ‒ – — ― −）をすべて '-' に畳んで比較する。
    -- ← U+2015「―」(横棒) が漏れており「レヴィ―ル」が別物件化していた取りこぼしを修正。
    (
      l1.layout = l2.layout
      AND ABS(l1.area_m2 - l2.area_m2) <= 3
      AND TRANSLATE(l1.normalized_name, 'ーｰ－‐‑‒–—―−', '----------')
        = TRANSLATE(l2.normalized_name, 'ーｰ－‐‑‒–—―−', '----------')
    )
    -- (B) 住所の区が一致し、総戸数も一致（名前が違うが同一建物の可能性）
    OR (
      l1.layout = l2.layout
      AND ABS(l1.area_m2 - l2.area_m2) <= 3
      AND l1.total_units = l2.total_units
      AND l1.total_units IS NOT NULL
      AND SUBSTRING(l1.address FROM '.+?区') = SUBSTRING(l2.address FROM '.+?区')
      AND LENGTH(l1.normalized_name) > 3
      AND LENGTH(l2.normalized_name) > 3
    )
    -- (C) 住所丁目+築年が一致（英語↔カタカナ等、名前の表記体系が異なるケース）
    -- 間取り・面積の制約を緩和し、同一建物の別表記を広く拾う
    -- 住所の丁目番号は全角（２）/半角（2）が混在する。\d の全角マッチは
    -- サーバの lc_ctype 依存で不安定なため、[0-9０-９] で明示的に両対応させる（防御的）。
    OR (
      SUBSTRING(l1.address FROM '.+?[区市].+?[0-9０-９]+') = SUBSTRING(l2.address FROM '.+?[区市].+?[0-9０-９]+')
      AND LENGTH(SUBSTRING(l1.address FROM '.+?[区市].+?[0-9０-９]+')) > 3
      AND LENGTH(l1.normalized_name) > 3
      AND LENGTH(l2.normalized_name) > 3
    )
  )
LIMIT 30;
```

2. 各ペアについてAI（自分自身）で判定する。以下の観点で分析。

   - 名前の比較: 表記揺れか？ 次の違いを確認する。
     - ダッシュの種類違い、全角/半角、スペース有無、タワー名の有無
     - 英語↔カタカナ変換、三点リーダー・装飾文字の残存、副名やカタカナ読みの付加
   - スペック比較: 面積・階数・築年・住所が一致または近似するか？
   - 価格比較: 価格差が20%以内か？
   - 間取り比較: 表記が異なるだけで同一か？（`2SLDK` = `2LDK+S（納戸）`等）

   判定結果
   | 結果 | 条件 | アクション |
   |------|------|-----------|
   | `merge` | 同一物件（同じ部屋） | 古い方or enrichment少ない方を`is_active = false`に。元の方の`alt_urls`にURLを追加 |
   | `same_building` | 同一マンション別部屋 | `normalized_name`を統一（より正式な方に合わせる） |
   | `different` | 別物件 | スキップ |

   `same_building`判定のガイドライン: 以下のいずれかに該当すれば同一マンションとみなす。
   - 英語名とカタカナ名が対応している（例: `BrilliaCity` = `ブリリアシティ`）
   - 一方が他方の副名・読み仮名を含む（例: `AQUAVISTA` vs `AQUAVISTAアクアヴィスタ`）
   - 装飾文字（三点リーダー`…`/`...`、`【】`内テキスト）を除けば同一
   - 住所・築年・総戸数が一致し、名前が類似している

3. `merge`判定の場合は次を実行する。
   ```sql
   -- マージ先に alt_sources 追加（enrichments 側）
   UPDATE enrichments
   SET alt_sources = COALESCE(alt_sources, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
     'source', (SELECT ls.source FROM listing_sources ls WHERE ls.listing_id = <remove_id> AND ls.is_active LIMIT 1),
     'url', (SELECT ls.url FROM listing_sources ls WHERE ls.listing_id = <remove_id> AND ls.is_active LIMIT 1)
   ))
   WHERE listing_id = <keep_id>;

   -- マージ元のソースを無効化し、tombstone 化（merged_into で統合先を指す）
   UPDATE listing_sources SET is_active = false WHERE listing_id = <remove_id>;
   UPDATE listings SET is_active = false, merged_into = <keep_id> WHERE id = <remove_id>;
   ```

   tombstoneを再アクティブ化しないための規則
   - `merged_into`を必ずセットする。is_active=falseだけでは再アクティブ化を防げない。
     掲載元がページを掲載し続ける限り、スクレイパー同期が毎朝再アクティブ化するためである。
     照合にはidentity_keyの完全一致を使う。
     merged_intoが付いていれば、スクレイパーは統合先へリダイレクトする。
   - マージ元（tombstone）の`name` / `normalized_name` / `identity_key`は修正しない。
     スクレイパーが再計算するidentity_keyと一致し続けることで、リダイレクトが成立する。
     プロモーション文言の入った名前を修正すると、identity_keyが一致しなくなる。
     その結果、同じ不要な名前で重複が再作成される。
   - 統合URLの記録は`enrichments.alt_sources`を使う。`listings.alt_urls`は
     スクレイパーが毎回上書きするため手動追加が消える。

4. `same_building`判定の場合は次を実行する。
   ```sql
   UPDATE listings SET normalized_name = '<統一名>' WHERE id IN (<id_a>, <id_b>);
   ```

   注意: `normalized_name`はスクレイパー同期が掲載ページの名前から毎回再計算して上書きする。
   掲載元の表記が原因の揺れ（ケとヶなど）は、次回スクレイプで元に戻る。
   恒久的に統一するには、`normalize_listing_name()`（report_utils.py）で吸収する必要がある。
   normalizeで吸収できない揺れは統一を見送り、レポートに記録するだけにする。

対象が0件ならスキップしてStep 1へ。

---

## Step 1: セマンティック重複排除

1. プロンプト取得
```sql
SELECT * FROM get_active_prompt('dedup');
```

2. 対象取得
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('dedup');
```

listing_dataには物件の基本情報に加え、`group_members`配列が含まれる。
`group_members`は同一マンション内の候補物件リストである。
normalized_nameが一致するか、住所・階数・総戸数が一致する物件が入る。

3. ペア比較の方法: listing_dataの物件（親）と`group_members`内の各物件（候補）を1対1で比較する。
   - 親物件の情報: listing_dataのトップレベルフィールド
     - name, normalized_name, layout, area_m2, floor_position等
   - 候補物件の情報: `group_members`配列内の各オブジェクト
   - `group_members`がnullまたは空配列の場合はスキップ
   - 各ペアについてsystem_promptに従い分析。user_prompt_templateの物件Aに親物件、物件Bに候補物件を埋め込む

4. 結果書き戻し
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'dedup', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

対象がなければスキップしてStep 2へ。

---

## Step 2: テキスト特徴抽出

1. プロンプト取得
```sql
SELECT * FROM get_active_prompt('text_enricher');
```

2. 対象取得
```sql
SELECT listing_id, listing_data FROM get_listings_for_ai('text_enricher');
```

`feature_tags IS NOT NULL`のアクティブ物件だけが返される。feature_tagsが空の物件は対象外。

3. 各物件についてsystem_promptに従い分析。user_prompt_templateのプレースホルダーにlisting_dataのフィールドを埋め込む。

   各物件は必ずsystem_promptを使って1件ずつAIで分析する。Pythonスクリプト、ルールベース処理、キーワードマッチングは禁止。

   - listings_feedに存在するフィールドは次のとおり。
     - name, address, layout, area_m2
     - built_year, floor_position, floor_total, total_units
     - management_fee, repair_reserve_fund, feature_tags
     - key_strengths, key_risks, ownership, direction, parking等
   - 注意: `remarks`や`equipment`はlistings_feedに存在しない。テンプレートに含まれていてもnullとして扱う
   - 値がnullの場合は「不明」と記載

4. 結果書き戻し
```sql
SELECT upsert_ai_enrichment(<listing_id>::bigint, 'text_enricher', '<結果JSON>'::jsonb, 'claude-sonnet-4-6', '<prompt_hash>', <version>, 'routine');
```

対象がなければスキップしてStep 3へ。

---

## Step 3: 通勤時間更新（マスタ参照方式）

方針: `station_commute_times`マスタテーブル（330駅以上）と`batch_update_commute_from_master()` RPCを使う。物件の最寄り駅から2オフィスへの通勤時間を一括更新する。APIとWebFetchは使用しない。

1. バッチ更新の実行
```sql
SELECT * FROM batch_update_commute_from_master(100);
```

結果は`(listing_id, station_name, status)`の配列で、statusは`updated`、`not_in_master`、`parse_failed`のいずれかになる。

2. `not_in_master`の駅がある場合
   - 同一路線の隣接駅データをマスタから探して推定値をINSERTし、再度バッチ実行
   - 推定値は`source = 'estimated_from_nearby'`, `confidence = 'estimated'`で記録
   - 推定が難しい駅は一覧にして報告する（Coworkでの手動補完用）

3. 結果が0件になるまで繰り返す（1回あたり最大100件）。

対象がなければスキップ。

---

## 完了レポート

全ステップの完了後、次のテンプレートに値を埋めたマークダウンブロックをチャットに出力する。
ユーザーはこの出力をそのままログファイルにコピペする。前後にテキストを付けず、テンプレート通りに出力する。

````markdown
## {YYYY-MM-DD} - ルーティン① 完了レポート

### 実行サマリー

| ステップ | 処理件数 | ステータス |
|---|---|---|
| Step 0: ヘルスチェック | - | ✅/⚠️ |
| Step 0.5: データ品質 | 自動削除X件、AI検証Y件（修正Z件、削除W件） | ✅/スキップ |
| Step 0.7: ファジー重複 | X件検出（merge Y件、統一Z件） | ✅/スキップ |
| Step 1: 重複排除 | X件（merge Y件、flag Z件） | ✅/スキップ |
| Step 2: テキスト特徴抽出 | X件 | ✅/スキップ |
| Step 3: 通勤時間更新 | X件（ヒットY件、parse_failed Z件） | ✅/スキップ |

### アラート
- {アラート内容。なければ「なし」}

### エラー
- {エラー内容。なければ「なし」}
````

---

## ファイル操作の禁止

リモート実行環境にはGitHubへの書き込み権限がないので、次の操作は**すべて禁止**する。
- ログファイルの読み書き・編集
- `git add` / `git commit` / `git push`
- GitHub MCPの`push_files` / `create_branch`

ログファイルの更新はユーザーがローカル環境で行う。

---

## 共通ルール
- サブエージェント委任禁止: 全ステップの処理をメインエージェントのコンテキストで実行する。サブエージェント（Agentツール）への委任は禁止
- AI分析必須: Step 1-2の各物件を1件ずつAIで分析する。分析にはget_active_prompt()で取得したsystem_promptを使う。Pythonスクリプト、ルールベース処理、一括バッチ処理、Fetch-Then-Ignoreパターンは禁止
- エラーが発生しても他の物件・ステップの処理は続行する
- 対象が0件のステップはスキップして次へ進む
- 日本語で回答する
