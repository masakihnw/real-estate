# Notion 連携ツール

スクレイピング結果（物件一覧）を Notion のデータベースに同期し、各物件ページの詳細に SUUMO の物件ページを **Notion Web Clipper のように** ウェブサイトとして保存します。

## 機能

- **データベース同期**: 表のカラム（物件名・価格・住所・詳細・駅徒歩・専有面積・間取り・築年 など）をそのまま Notion の DB カラムとして追加
- **販売状況**: 販売中 / 売り切れの2択。レポートから削除された物件は Notion で販売状況が「売り切れ」に更新されます
- **ページ本文**: 各 Notion ページに物件詳細 URL を「ブックマーク（リンクプレビュー）」＋「Embed（URL のウェブページを埋め込み表示）」で保存。HTML の取得・保存は行いません

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
| 名前                  | Title      | 物件名                           |
| 詳細                  | URL        | SUUMO/HOME'S の詳細URL           |
| 価格（万円）          | Number     | 価格（万円）                     |
| 区                    | Select     | 住所から取得した区名（漢字。例: 文京区。存在しない選択肢は Notion が自動作成） |
| 住所                  | Text       | 住所                             |
| 路線・駅              | Text       | 路線・駅                         |
| 徒歩（分）            | Number     | 徒歩（分）                       |
| 専有面積（㎡）        | Number     | 専有面積（㎡）                   |
| 間取り                | Select     | 間取り（存在しない選択肢は Notion が自動作成） |
| 築年数                | Number     | 築年（年）                       |
| 総戸数                | Number     | 総戸数                           |
| 所在階                | Number     | 所在階                           |
| 階建                  | Number     | 階建                             |
| 権利形態              | Select     | 権利形態（必須。未取得時は「不明」） |
| 販売状況              | Status     | 販売中 / 売り切れの2択            |
| PG                    | Number     | 通勤時間（分）playground（一番町）     |
| M3                    | Number     | 通勤時間（分）エムスリーキャリア（虎ノ門） |
| Google Map            | URL        | 住所から生成した Google マップの検索URL |

**販売状況（Status）について**: Notion API では Status プロパティの新規作成ができないため、データベース作成後に Notion 上で「販売状況」プロパティ（タイプ: Status）を追加し、選択肢「販売中」「売り切れ」の2つを設定してください。

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

### 2. ローカルで同期テスト

1. 上記のとおり `NOTION_TOKEN` と `NOTION_DATABASE_ID` を export する。
2. まず dry-run で対象件数だけ確認する:
   ```bash
   python3 notion-tool/sync_to_notion.py results/latest.json --dry-run
   ```
3. 問題なければ本番同期する。前回結果（`results/previous.json`）があれば差分のみ、なければ全件:
   ```bash
   # 前回結果がある場合（定期実行後など）
   python3 notion-tool/sync_to_notion.py results/latest.json --compare results/previous.json
   # 前回結果がない場合（初回や全件同期したい場合）
   python3 notion-tool/sync_to_notion.py results/latest.json
   ```
4. Notion のデータベースでページが増え、物件を開いてブックマーク・Embed が入っていれば成功。

### 3. 自動で Notion に同期されるようにする

**GitHub Actions で自動実行（推奨）**

1. GitHub でリポジトリを開く → **Settings** → **Secrets and variables** → **Actions**
2. **New repository secret** で次の2つを追加する:
   - **Name**: `NOTION_TOKEN`  
     **Secret**: Notion インテグレーションのトークン（`secret_...` または `ntn_...`）
   - **Name**: `NOTION_DATABASE_ID`  
     **Secret**: 物件用データベースの ID（32文字）
3. 保存後、「Update Listings」ワークフローが実行されるたびに（毎日 cron または手動実行）、**変更があった場合**にスクリプト内で自動で Notion へ同期されます。別途コマンドを打つ必要はありません。

**Slack 投稿や Notion 同期が行われない場合**  
今回の取得結果と前回（`latest.json`）に**差分がなかった**とき、スクリプトは「変更なし」で早期終了し、`latest.json` やレポートを更新しません。そのため git に変更が残らず、ワークフローの「Check for changes」で `changed=false` となり、Slack 通知も Notion 同期も実行されません（設計どおりの動作です）。

**ローカルで定期実行する場合**

`scripts/update_listings.sh` を cron などで実行する前に、環境変数を設定してください。

```bash
export NOTION_TOKEN="your-token"
export NOTION_DATABASE_ID="your-database-id"
./scripts/update_listings.sh
```

（`.env` を用意して `set -a; source .env; set +a` で読み込む方法でも可）

- **同期ルール**: 各物件は `url` で一意とみなします。同じ URL のページが既に Notion にあればプロパティを更新し、なければ新規作成してページ本文に「ブックマーク＋Embed」を保存します。**取得情報の変更**（価格・総戸数・専有面積・徒歩・築年数など、Notion に送るいずれかの項目が前回と異なる）があれば、その物件は「更新」として Notion のプロパティを上書きします。**レポートから削除された物件**は、既存の Notion ページの販売状況が「売り切れ」に更新されます。
- **Select カラム**: 存在しない選択肢は Notion が新規作成し、既存のものはそのまま選択します。同じ名前の選択肢が2つ以上作られることはありません。
- **Web Clipper 風の保存**: 新規作成時は物件詳細 URL で「ブックマーク」と「Embed」ブロックを追加します。Notion が URL のプレビュー・埋め込みを表示します（対応ドメインは Iframely により表示。未対応の場合はリンクとして表示）。HTML の取得は行わないため SUUMO への負荷が少なく、同期が軽くなります。

## 定期実行での利用

`scripts/update_listings.sh` および GitHub Actions のワークフローでは、Slack 通知と同時に Notion 同期が実行されます。**上記「3. GitHub Actions で自動同期する」**で Secrets を登録すると、変更があったときだけ自動で Notion に同期されます。

## 注意

- SUUMO の利用規約に従い、私的利用・軽負荷で利用してください。
- Notion API のレート制限（リクエスト数/時間）に注意してください。件数が多い場合は `--limit` で一度に同期する件数を制限できます。
