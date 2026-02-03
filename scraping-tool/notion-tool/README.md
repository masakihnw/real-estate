# Notion 連携ツール

スクレイピング結果（物件一覧）を Notion のデータベースに同期し、各物件ページの詳細に SUUMO の物件ページを Web Clipper のように保存します。**ページ内画像も保存**されます。

## 機能

- **データベース同期**: 表のカラム（物件名・価格・住所・駅徒歩・専有面積・間取り・築年・URL など）をそのまま Notion の DB カラムとして追加
- **売り切れ**: レポートから削除された物件は Notion で「売り切れ」カラムにチェックが入るよう同期
- **ページ本文**: 各 Notion ページに SUUMO の物件詳細ページを「ブックマーク（リンクプレビュー）」＋「ページ内画像」＋「保存時点の HTML 全文」で保存

## セットアップ

### 1. Notion でインテグレーションを作成

1. [Notion Integrations](https://www.notion.so/my-integrations) を開く
2. 「New integration」で新しいインテグレーションを作成
3. **Internal Integration Token**（`secret_...`）をコピー

### 2. Notion でデータベースを用意

**手動で作成する場合:**

1. Notion で新規ページを作成し、その中に「データベース」を追加（Table - Inline または Full page）
2. 以下のプロパティを追加（名前とタイプを合わせる）:

| プロパティ名 (Notion) | タイプ     | 対応する項目                     |
|-----------------------|------------|----------------------------------|
| 名前 (Name)           | Title      | 物件名                           |
| url                   | URL        | URL           |
| price_man             | Number     | 価格（万円）                     |
| address               | Text       | 住所                             |
| station_line          | Select     | 路線・駅                         |
| walk_min              | Number     | 徒歩（分）                       |
| area_m2               | Number     | 専有面積（㎡）                   |
| layout                | Text       | 間取り                           |
| built_year            | Number     | 築年（年）                       |
| total_units           | Number     | 総戸数                           |
| floor_position        | Number     | 所在階                           |
| floor_total           | Number     | 階建                             |
| list_ward_roman       | Select     | 区（ローマ字）                   |
| ownership             | Select     | 権利形態（必須。未取得時は「不明」） |
| ステータス            | Status     | 販売中 / 売り切れの2択。レポートから削除された物件は「売り切れ」 |

1. データベースの「…」→「接続」で、上記で作ったインテグレーションを接続
2. データベースの URL から **Database ID** を取得  
   例: `https://www.notion.so/workspace/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx?v=...`  
   → `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` の部分（32文字。ハイフンなしでも可）

**スクリプトで自動作成する場合:**

親ページの ID を用意し、以下を実行すると上記スキーマでデータベースを作成します。

```bash
cd scraping-tool
NOTION_TOKEN="secret_xxx" NOTION_PARENT_PAGE_ID="親ページのUUID" python3 notion-tool/create_database.py
```

### 3. 環境変数

| 変数名 | 説明 |
|--------|------|
| `NOTION_TOKEN` | Notion インテグレーションのトークン（必須） |
| `NOTION_DATABASE_ID` | 物件用データベースの ID（必須） |

## 使い方

**scraping-tool ディレクトリで実行:**

```bash
cd scraping-tool
export NOTION_TOKEN="secret_xxx"
export NOTION_DATABASE_ID="your-database-id"

# 最新結果を Notion に同期（新規は追加、既存は URL で判定して更新）
python3 notion-tool/sync_to_notion.py results/latest.json

# 差分のみ同期（新規・価格変動のみ。前回結果が必要）
python3 notion-tool/sync_to_notion.py results/latest.json --compare results/previous.json
```

- **同期ルール**: 各物件は `url` で一意とみなします。同じ URL のページが既に Notion にあればプロパティを更新し、なければ新規作成してページ本文に SUUMO 詳細のブックマーク＋画像＋HTML を保存します。**レポートから削除された物件**（売り切れ）は、既存の Notion ページの「売り切れ」にチェックが入るよう更新します。
- **Select カラム**: データベースに既に存在する選択肢だけを設定します。未登録の値は設定せず、新規の選択肢は Notion に作成しません。事前に Notion で選択肢を追加しておいてください。
- **SUUMO 詳細の保存**: 新規作成時（および `--refresh-html` 指定時）に、物件の詳細 URL へ 1 回だけアクセスして HTML を取得し、Notion ページの本文に「ブックマーク」「ページ内画像（最大30枚）」「HTML 全文（コードブロック）」として追加します。SUUMO への負荷軽減のため、リクエスト間に遅延を入れています。

## 定期実行での利用

`scripts/update_listings.sh` および GitHub Actions のワークフローでは、Slack 通知と同時に Notion 同期を実行するように設定できます。

- ワークフローに `NOTION_TOKEN` と `NOTION_DATABASE_ID` のシークレットを追加
- 「Send Slack notification」のあと（または並列で）「Sync to Notion」ステップを追加し、`python3 notion-tool/sync_to_notion.py results/latest.json --compare results/previous.json` を実行

## 注意

- SUUMO の利用規約に従い、私的利用・軽負荷で利用してください。
- Notion API のレート制限（リクエスト数/時間）に注意してください。件数が多い場合は `--limit` で一度に同期する件数を制限できます。
