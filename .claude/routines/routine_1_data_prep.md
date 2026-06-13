# ルーティン①: データクレンジング

- **スケジュール**: 毎日 JST 3:00（1回/日）
- **MCP**: Supabase（必須）
- **所要時間目安**: 15-25分

---

## 概要

不動産物件データのクレンジング・エンリッチメントを行う。
後続のルーティン②（スコアリング & 画像分析）が依存するため、先に実行する。

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
  -- name にプロモーション文言（×区切りタグ等）が含まれ、normalized_name と大きく異なる
  OR (
    l.name ~ '[×【】]'
    AND l.name != l.normalized_name
    AND LENGTH(l.name) > LENGTH(l.normalized_name) + 10
  )
)
ORDER BY l.created_at DESC
LIMIT 30;
```

2. 各レコードを AI（自分自身）で判定する。以下の観点で判断:

   - **name** と **normalized_name** は正当な日本のマンション・物件名か？
   - 説明文・特徴タグ・ページタイトルが物件名になっていないか？
   - 同一住所・同一スペックの正しい名前のレコードが既に存在しないか？
   - **`name` にプロモーション文言（ペット可×南向き等の×区切りタグ、【】内の修飾語）が含まれ、`normalized_name` と大きく異なる場合**: `name` を `normalized_name` の値で上書きする（`UPDATE listings SET name = normalized_name WHERE id = <id>`）

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

対象が0件ならスキップして Step 0.7 へ。

---

## Step 0.7: AI ファジー重複検出

既存の Step 1（セマンティック重複排除）は `normalized_name` 完全一致で候補を絞り込むため、
ダッシュバリアント（ー vs -）や微妙な表記揺れを見逃す。
また、英語↔カタカナの表記差（`BrilliaCity西早稲田` vs `ブリリアシティ西早稲田`）、
三点リーダーの残存（`AQUAVISTA...`）、間取り表記揺れ（`2SLDK` vs `2LDK+S`）等により
同一マンション・同一部屋が別物件として扱われ、Slack通知で誤った「入れ替え」として報告される。
このステップではより広い候補をAIに判定させ、即座に修正する。

1. 候補ペア取得:
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
    (
      l1.layout = l2.layout
      AND ABS(l1.area_m2 - l2.area_m2) <= 3
      AND TRANSLATE(l1.normalized_name, 'ー－‐–—', '-----')
        = TRANSLATE(l2.normalized_name, 'ー－‐–—', '-----')
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
    OR (
      SUBSTRING(l1.address FROM '.+?[区市].+?\d+') = SUBSTRING(l2.address FROM '.+?[区市].+?\d+')
      AND LENGTH(SUBSTRING(l1.address FROM '.+?[区市].+?\d+')) > 3
      AND LENGTH(l1.normalized_name) > 3
      AND LENGTH(l2.normalized_name) > 3
    )
  )
LIMIT 30;
```

2. 各ペアについてAI（自分自身）で判定する。以下の観点で分析:

   - **名前の比較**: 表記揺れか？（ダッシュの種類違い、全角/半角、スペース有無、タワー名の有無、**英語↔カタカナ変換**、三点リーダー・装飾文字の残存、副名やカタカナ読みの付加）
   - **スペック比較**: 面積・階数・築年・住所が一致または近似するか？
   - **価格比較**: 価格差が20%以内か？
   - **間取り比較**: 表記が異なるだけで同一か？（`2SLDK` = `2LDK+S（納戸）` 等）

   判定結果:
   | 結果 | 条件 | アクション |
   |------|------|-----------|
   | `merge` | 同一物件（同じ部屋） | 古い方 or enrichment 少ない方を `is_active = false` に。元の方の `alt_urls` に URL を追加 |
   | `same_building` | 同一マンション別部屋 | `normalized_name` を統一（より正式な方に合わせる） |
   | `different` | 別物件 | スキップ |

   **`same_building` 判定のガイドライン**: 以下のいずれかに該当すれば同一マンションとみなす:
   - 英語名とカタカナ名が対応している（例: `BrilliaCity` = `ブリリアシティ`）
   - 一方が他方の副名・読み仮名を含む（例: `AQUAVISTA` vs `AQUAVISTAアクアヴィスタ`）
   - 装飾文字（三点リーダー `…`/`...`、`【】`内テキスト）を除けば同一
   - 住所・築年・総戸数が一致し、名前が類似している

3. `merge` 判定の場合:
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

   **⚠️ tombstone の鉄則（蘇生防止）**:
   - `merged_into` を必ずセットすること。is_active=false だけでは、掲載元がページを
     掲載し続ける限りスクレイパー同期が identity_key 完全一致で**毎朝再アクティブ化**する
     （merged_into 付きならスクレイパーは統合先へリダイレクトする）。
   - マージ元（tombstone）の `name` / `normalized_name` / `identity_key` は**修正しない**こと。
     スクレイパーが再計算する identity_key と一致し続けることでリダイレクトが成立する。
     プロモーション文言の名前を「修正」すると照合が切れ、同じ junk 名で**重複が再作成**される。
   - 統合URLの記録は `enrichments.alt_sources` を使う。`listings.alt_urls` は
     スクレイパーが毎回上書きするため手動追加が消える。

4. `same_building` 判定の場合:
   ```sql
   UPDATE listings SET normalized_name = '<統一名>' WHERE id IN (<id_a>, <id_b>);
   ```

   **⚠️ 注意**: `normalized_name` はスクレイパー同期が掲載ページの名前から毎回再計算して
   上書きするため、掲載元の表記が原因の揺れ（ケ/ヶ等）は次回スクレイプで元に戻る。
   恒久統一には `normalize_listing_name()`（report_utils.py）側での吸収が必要。
   揺れが normalize で吸収できないケースは統一を見送り、レポートに記録するだけにする。

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

## ~~Step 3: AI 動的スコアリング~~ （ルーティン②に移動）

AI スコアリング（ai_scoring モジュール）はバイヤープロファイル依存のため、
ルーティン②（スコアリング & 画像分析）に移動済み。

---

## Step 3: 通勤時間更新（マスタ参照方式）

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

## ~~Step 5: HOME'S 画像取得~~ （廃止 → GitHub Actions に移行）

HOME'S 画像の取得はクラウドコンテナのネットワーク制限（homes.co.jp がブロック）により
ルーティンからは実行不可。GitHub Actions ワークフロー `backfill-homes-images` に移行済み。

CI パイプライン（`run_enrich.sh` Track G）がローカル/GHA 環境で自動的に新着物件の画像を取得する。

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

リモート実行環境には GitHub への書き込み権限がないため、以下の操作は**すべて禁止**:
- ログファイルの読み書き・編集
- `git add` / `git commit` / `git push`
- GitHub MCP の `push_files` / `create_branch`

ログファイルの更新はユーザーがローカル環境で行う。

---

## 共通ルール
- **サブエージェント委任禁止**: 全ステップの処理はメインエージェントのコンテキストで実行すること。サブエージェント（Agent ツール）への委任は禁止
- **AI 分析必須**: Step 1-2 の各物件は必ず get_active_prompt() で取得した system_prompt を使って1件ずつ AI で分析すること。Python スクリプト、ルールベース処理、一括バッチ処理、Fetch-Then-Ignore パターンは**禁止**
- エラーが発生しても他の物件・ステップの処理は続行する
- 対象が0件のステップはスキップして次へ進む
- 日本語で回答すること
