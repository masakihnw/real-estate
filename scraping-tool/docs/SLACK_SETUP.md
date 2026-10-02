# Slack通知のセットアップ

物件情報の更新をSlackに通知するためのセットアップ手順です。

## 1. Slack Incoming Webhookの作成

1. Slack Appを作成します。
   - https://api.slack.com/apps にアクセスします。
   - 「Create New App」から「From scratch」を選びます。
   - App名は `real-estate-notifier` にします（任意）。
   - ワークスペースを選びます。

2. Incoming Webhooksを有効化します。
   - 左メニューの「Incoming Webhooks」を開きます。
   - 「Activate Incoming Webhooks」をONにします。

3. Webhook URLを取得します。
   - 「Add New Webhook to Workspace」をクリックします。
   - 通知を送信したいチャンネルを選びます（例: `#real-estate`）。
   - 「Allow」をクリックします。
   - 表示されたWebhook URLをコピーします。形式は `https://hooks.slack.com/services/（ワークスペースID）/（チャンネルID）/（トークン）` です。

## 2. GitHub Secretsに設定

1. GitHubリポジトリを開きます。
   - 例: https://github.com/masakihnw/real-estate（またはあなたのリポジトリ）

2. Settings、Secrets and variables、Actions の順に開きます。

3. 「New repository secret」をクリックします。
   - Name: `SLACK_WEBHOOK_URL`
   - Secret: 上記で取得したWebhook URLを貼り付けます。

4. 「Add secret」をクリックします。

### Webhook（通知チャンネル）の使い分け

通知は、チャンネルごとに別々のWebhook URLで送り分けます。チャンネルはWebhookの作成時に決まります。別のチャンネルへ送りたい場合は、そのチャンネル向けのWebhookを発行し、対応するSecretに設定してください。

| Secret名 | 用途 | 未設定時の挙動 |
|-----------|------|----------------|
| `SLACK_WEBHOOK_URL` | 物件更新通知（新規、削除、入れ替え、注目物件の値下げ）のメインチャンネル | 通知をスキップ（exit 0） |
| `SLACK_HEALTH_WEBHOOK_URL` | スクレイパー健全性アラート、建物名データ品質アラート、`pipeline_health_report` | `SLACK_WEBHOOK_URL` にフォールバック |
| `SLACK_ALERT_WEBHOOK_URL` | enrichmentカバレッジアラート（`check_enrichment_health.py`） | `SLACK_WEBHOOK_URL` にフォールバック |

スクレイパー健全性アラートと建物名データ品質アラートを、物件更新とは別のチャンネルに投稿したい場合は、設定が必要です。
そのチャンネル向けのWebhookを `SLACK_HEALTH_WEBHOOK_URL` に設定してください（`slack_notify.py` の `_send_health_alerts`）。

## 2.5 削除物件をスレッド返信にする（任意・Botトークン）

既定では、削除物件は本文の中にまとめて表示されます。削除物件のブロックを本文のスレッド返信として送るには、Slack Web API（`chat.postMessage`）が必要です。Incoming Webhookはメッセージの `ts` を返さず、スレッド返信ができないためです。

設定すると、次の動作になります。

- 本文（新規、入れ替え、注目物件の値下げ、AIダイジェスト）をトップレベルに投稿します。
- 削除された物件の明細を、その投稿のスレッド返信として送ります。本文には件数のサマリーだけが残ります。
- Botトークンが未設定の場合は、従来どおり1通にインライン表示します（後方互換のフォールバックです）。

### 手順

1. Bot Token Scopesを追加します。
   - https://api.slack.com/apps で対象のアプリを開きます。
   - 「OAuth & Permissions」の「Scopes」にある「Bot Token Scopes」へ、`chat:write` を追加します。
2. ワークスペースにインストール（再インストール）します。
   - 同じページ上部の「Install to Workspace」または「Reinstall to Workspace」を押します。
   - 表示された Bot User OAuth Token（`xoxb-...`）をコピーします。
3. Botを投稿先のチャンネルに招待します。
   - 対象のチャンネルで `/invite @real-estate-notifier`（アプリ名）を実行します。
4. チャンネルIDを取得します。
   - チャンネル名をクリックし、「チャンネル詳細」の最下部にあるID（`C0XXXXXXX`）をコピーします。
   - Webhookと同じチャンネルのIDにしてください。投稿先がずれるのを防ぐためです。
5. GitHub Secretsに登録します。
   - `SLACK_BOT_TOKEN` に `xoxb-...` を設定します。
   - `SLACK_CHANNEL_ID` に `C0XXXXXXX` を設定します。

`SLACK_WEBHOOK_URL` は残してください。未設定だと通知自体がスキップされます。Botトークン未設定時のフォールバック送信にも、このURLを使います。スレッド返信モードになる条件は、`SLACK_BOT_TOKEN` と `SLACK_CHANNEL_ID` の両方が揃っていることです。

スレッド返信の送信だけを確認する手動ワークフロー `slack-smoke-test.yml`（Slack Thread Smoke Test）があります。合成データを1回だけ投稿し、本番の通知基準時刻は進めません。

## 3. 投稿する物件のフィルタ条件

Slackに投稿するのは、資産性ランクがB以上（S、A、B）の物件だけです。

- ランクは、10年後の値上がり試算（`price_predictor`）と共通のアルゴリズムで算出します。判定には含み益率を使います。含み益率は、10年後Standard価格から10年後ローン残債を引いた額を、現在の成約推定価格で割った値です。
- Sは含み益率10%以上、Aは5%以上、Bは0%以上、Cは0%未満です。
- 一覧に載る物件と、新規追加、削除、入れ替えは、このS、A、Bに絞った結果だけを表示します。

`slack_notify.py` は `generate_report` に依存しません。資産性、10年後予測、通勤時間などは `optional_features.py` 経由で利用します。`SLACK_WEBHOOK_URL` が未設定の場合は、警告を出して exit 0 でスキップします。

### 投稿のタイミング

- Slack通知は、2026-07-07から全経路で停止しています。環境変数 `SLACK_NOTIFICATIONS_ENABLED=1` を設定したときだけ送信します（[README.md](../README.md) を参照）。以下は送信を再開した場合の動作です。
- Slackの差分通知は、GitHub Actions の `Enrich and Report` ワークフローの finalize ジョブが `slack_notify.py` を呼んで送ります。
  送信対象になるのは、Scrape Listings の開始がUTC 0〜5時（JST 9:00の回）だったときだけです。
  詳しくは [GITHUB_SETUP.md](./GITHUB_SETUP.md) の「スケジュールと動作」を参照してください。
- 資産性B以上の新規と削除がなく、注目物件の値下げも、送信待ちのAIダイジェストもない場合は、投稿をスキップします。
- 新規がなく削除だけの差分では、注目物件の値下げかAIダイジェストがない限り、通知を保留します。
- 差分がある場合は、冒頭に「■ 今回の変更」（入れ替え、新規追加、削除の件数）を出し、該当する物件を投稿します。

### 差分の判定

同一物件のキーは `identity_key`（名前、間取り、広さ、住所の丁目まで、築年、所在階）です。価格、駅名、徒歩分数はキーに含まれません。所在階は、前回と今回の両方に値がある場合だけ区別されます。価格だけが変わった物件は同じ物件なので、新規にも削除にもなりません。

同じマンションで新規と削除が同時に出た場合は、「同一マンション内の入れ替え」としてまとめます。

## 4. 動作確認

`SLACK_NOTIFICATIONS_ENABLED=1` を設定した場合は、次回のワークフロー実行時または手動実行時に、変更があればSlackに通知が届きます。
設定していない場合、Slackには何も届かず、送信をスキップしたことを示すログだけが残る。

通知の内容は次のとおりです。

- 見出しと、対象件数（資産性B以上の件数と全件数）
- レポートと、ピン付き地図へのリンク
- 今回の変更（入れ替え、新規追加、削除の件数）
- 同一マンション内の入れ替え（削除と新規の階と価格）
- 新規追加された物件（価格の安い順）
- 削除された物件（Botトークンが設定されている場合は、スレッド返信）
- 注目物件の値下げ（お気に入りと、資産性S、Aの物件）
- 送信待ちのAIダイジェスト

## 5. トラブルシューティング

### 通知が来ない

1. GitHub Secretsを確認します。
   - Settings、Secrets の `SLACK_WEBHOOK_URL` が正しく設定されているかを確認します。

2. ワークフローのログを確認します。
   - Actions タブで "Enrich and Report" の実行履歴を開きます。
     finalize ジョブの "Run finalize" ステップを見ます。
   - `Slack 差分通知スキップ（is_slack_time=false）` と出ている場合は、通知の時間帯ではない回です。
   - `変更なし（資産性B以上の新規・削除なし、注目値下げなし）Slack通知をスキップします` と出ている場合は、通知対象の差分がありません。

3. Webhook URLの有効性を確認します。
   - 次のコマンドでテストします（ローカル環境）。
     ```bash
     curl -X POST -H 'Content-type: application/json' \
       --data '{"text":"テスト通知"}' \
       YOUR_WEBHOOK_URL
     ```

### 通知を一時的に無効化

`SLACK_WEBHOOK_URL` をGitHub Secretsから削除すると、通知はスキップされます（エラーにはなりません）。
