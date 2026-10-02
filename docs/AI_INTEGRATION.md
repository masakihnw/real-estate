# AI Integration Guide

物件データ（listing_facts）と買い手プロファイル（buyer_profiles）をAI（Claude / ChatGPT）から直接分析するための設定ガイドです。

## アーキテクチャ

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  iOS App    │────▶│   Supabase   │◀────│  Scraping       │
│  (editor)   │     │              │     │  Pipeline       │
└─────────────┘     │  ┌─────────┐ │     └─────────────────┘
                    │  │listings │ │
┌─────────────┐     │  │enrichm. │ │
│  ChatGPT    │────▶│  │buyer_pr.│ │
│  (GPT)      │     │  └─────────┘ │
└─────────────┘     │              │
                    │  Views:      │
┌─────────────┐     │  listing_    │
│  Claude     │────▶│  facts       │
│  (MCP)      │     └──────────────┘
└─────────────┘
```

- listing_facts: 事実と第三者データのみを持つ。自前スコアを除外し、AIのバイアスを防ぐ
- buyer_profiles: 買い手プロファイル。iOSアプリ、パイプライン、外部AIが共通で参照する

## 1. Claude (MCP) 設定

### claude_desktop_config.jsonに追加

`~/Library/Application Support/Claude/claude_desktop_config.json` に次を追加します。

```json
{
  "mcpServers": {
    "supabase-real-estate": {
      "command": "npx",
      "args": [
        "-y",
        "@anthropic-ai/claude-code-mcp-server",
        "--supabase-url", "https://dzhcumdmzskkvusynmyw.supabase.co",
        "--supabase-key", "<YOUR_SERVICE_ROLE_KEY>"
      ]
    }
  }
}
```

> Supabase MCPが利用可能な場合は直接利用します。利用できない場合はPostgreSQL MCPを使います。

### 推奨システムプロンプト（Claude Projects）

```
あなたは不動産購入アドバイザーです。

## 手順
1. まず buyer_profiles テーブルから買い手プロファイルを読む（user_id = 'default'）
2. 買い手の条件（家族構成、予算、通勤、重視点）を把握する
3. listing_facts ビューから物件データを取得する
4. 買い手プロファイルと照合して分析する

## 分析の原則
- listing_facts は事実データのみ。分析・判断は全てあなたが行う
- 買い手の予算制約・ライフステージ・通勤条件を常に意識する
- 8〜10年後の売却を前提とした資産性を重視する
- テーブルの COMMENT を参照してカラムの意味を理解すること

## よく使うクエリ
- アクティブ物件: SELECT * FROM listing_facts WHERE status = 'active'
- エリア絞り込み: WHERE list_ward_roman IN ('koto', 'sumida', 'taito')
- 面積絞り込み: WHERE area_m2 >= 55
- 駅近: WHERE walk_min <= 7
```

## 2. ChatGPT (GPT Actions) 設定

### GPT Actionsの作成手順

1. ChatGPTで「GPT を作成」→「Actions」タブを開く
2. 「Import from URL」または「Schema」にOpenAPI specを貼り付ける。ファイルは `docs/openapi-listing-facts.yaml`
3. Authenticationを次のとおり設定する
   - Type: **API Key**
   - Auth Type: **Custom**
   - Custom Header Name: `apikey`
   - API Key: `<YOUR_SERVICE_ROLE_KEY>`
4. 追加ヘッダーに次を設定する
   - `Authorization: Bearer <YOUR_SERVICE_ROLE_KEY>`

### GPTの指示（Instructions）

```
あなたは不動産購入アドバイザーです。

## 手順
1. 最初に getBuyerProfile を呼び出す（p_user_id: "default"）
2. 買い手の条件を把握する
3. getListingFacts で物件を検索する
4. 買い手プロファイルと照合して分析・推奨する

## フィルタの使い方
PostgREST 形式のフィルタを使用:
- 等値: status=eq.active
- 以上: area_m2=gte.55
- 以下: walk_min=lte.7
- 含む: list_ward_roman=in.(koto,sumida)
- 並び替え: order=updated_at.desc
- 件数制限: limit=20

## 分析の原則
- データは事実のみ。判断は全てあなたが行う
- 買い手の予算・家族計画・通勤を必ず考慮する
- 8〜10年後の売却前提で資産性を評価する
```

## 3. クエリ例

### アクティブな3LDK物件（65㎡以上、駅7分以内）

```
GET /rest/v1/listing_facts?status=eq.active&layout=like.*LDK*&area_m2=gte.65&walk_min=lte.7&order=updated_at.desc&limit=20
```

### 江東区・墨田区のファミリー向け物件

```
GET /rest/v1/listing_facts?status=eq.active&list_ward_roman=in.(koto,sumida)&area_m2=gte.55&order=area_m2.desc&limit=30
```

### 価格変動があった物件

```
GET /rest/v1/listing_facts?status=eq.active&price_history_json=not.is.null&order=updated_at.desc&limit=20
```

### 買い手プロファイル取得

```
POST /rest/v1/rpc/get_buyer_profile
Content-Type: application/json

{"p_user_id": "default"}
```

## 4. カラムコメント

全テーブル・カラムに `COMMENT ON COLUMN` が設定済みです。
Claude MCPの `list_tables` や `\d+ listing_facts` で、カラムの意味が自動的に表示されます。

主なカラムは次のとおりです。

| カラム | 説明 |
|--------|------|
| `sources_json` | 全掲載サイトのURL・価格をJSONB配列で集約 |
| `commute_info_v2` | 通勤時間（自転車・電車、複数目的地対応） |
| `hazard_info` | ハザードマップ（洪水・高潮・土砂・津波・液状化） |
| `ss_profit_pct` | 住まいサーフィン含み益率予測 |
| `ss_value_judgment` | 住まいサーフィン割安/割高判定 |
| `reinfolib_market_data` | 国交省不動産取引価格情報 |
| `price_history_json` | 価格変動履歴（日付・価格・ソース） |

## 5. セキュリティ

- Service Role Keyを使用する（個人利用・2ユーザー限定）
- Keyは環境変数で管理し、コードにハードコードしない
- RLSは `service_role` に全アクセスを許可する。`anon` にはSELECTのポリシー `anon_read_own` があるが、条件が `true` のため全行を読み取れる（`supabase/migrations/020_listing_facts_and_buyer_profiles.sql`）
