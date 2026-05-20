# ルーティン①: データ準備 & スコアリング

- **スケジュール**: 毎日 JST 2:00
- **MCP**: Supabase（必須）
- **所要時間目安**: 15-30分

---

## 概要

不動産物件データのクレンジング・エンリッチメントを行う。
後続のルーティン②（AI分析 & ピック）が依存するため、先に実行する。

Supabase project_id: `dzhcumdmzskkvusynmyw`
全ての SQL は Supabase MCP の `execute_sql` で実行すること。

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
- 結果が0件（Routine 3 未実行）の場合はスキップして Step 1 へ進む

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

## ログ記録ルール

ログファイル `.claude/routines/logs/routine_1_data_prep_log.md` には **完了レポートのみ** を追記する。

**記録する内容**:
- 日付ヘッダー（`## YYYY-MM-DD HH:MM JST`）
- 各ステップの処理件数サマリー（テーブル形式）
- エラーがあった場合はエラー内容（1行）
- 完了レポートセクション全体で **50行以内**

**記録してはいけない内容**:
- MCP ツール出力の RAW JSON（`<untrusted-data>` タグ等）
- AI の内部思考・推論プロセス（英語テキスト含む）
- Python スクリプトのソースコード
- SQL クエリの全文（結果のみ要約で記録）
- ルーティン定義（プロンプト仕様書）
- 内部ファイルパス（`/root/.claude/...` 等）
- 物件データの全件一覧（件数のみ記録）

**ログの先頭にルーティン定義を含めないこと**。定義は `routine_1_data_prep.md` に存在するため重複記載は禁止。

---

## 共通ルール
- **サブエージェント委任禁止**: 全ステップの処理はメインエージェントのコンテキストで実行すること。サブエージェント（Agent ツール）への委任は禁止
- エラーが発生しても他の物件・ステップの処理は続行する
- 対象が0件のステップはスキップして次へ進む
- 日本語で回答すること
