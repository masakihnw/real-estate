# Slack通知のセットアップ

物件情報の更新をSlackに通知するためのセットアップ手順です。

## 1. Slack Incoming Webhook の作成

1. **Slack App を作成**
   - https://api.slack.com/apps にアクセス
   - 「Create New App」→「From scratch」を選択
   - App名: `real-estate-notifier`（任意）
   - ワークスペースを選択

2. **Incoming Webhooks を有効化**
   - 左メニュー「Incoming Webhooks」を開く
   - 「Activate Incoming Webhooks」を ON にする

3. **Webhook URL を取得**
   - 「Add New Webhook to Workspace」をクリック
   - 通知を送信したいチャンネルを選択（例: `#real-estate`）
   - 「Allow」をクリック
  - 表示された **Webhook URL** をコピー
    - 形式: `https://hooks.slack.com/services/（ワークスペースID）/（チャンネルID）/（トークン）`

## 2. GitHub Secrets に設定

1. **GitHub リポジトリを開く**
   - 例: https://github.com/masakihnw/real-estate（またはあなたのリポジトリ）

2. **Settings → Secrets and variables → Actions** を開く

3. **「New repository secret」をクリック**
   - Name: `SLACK_WEBHOOK_URL`
   - Secret: 上記で取得した Webhook URL を貼り付け

4. **「Add secret」をクリック**

### Webhook（通知チャンネル）の使い分け

通知は **チャンネルごとに別々の Webhook URL** で送り分けます。チャンネルは Webhook 作成時に紐づくため、別チャンネルへ送りたい場合はそのチャンネル向けの Webhook を発行し、対応する Secret に設定します。

| Secret 名 | 用途 | 未設定時の挙動 |
|-----------|------|----------------|
| `SLACK_WEBHOOK_URL` | 物件更新通知（新規・削除・値下げ等）のメインチャンネル | 通知をスキップ（exit 0） |
| `SLACK_HEALTH_WEBHOOK_URL` | **スクレイパー健全性アラート・建物名データ品質アラート** と `pipeline_health_report` | `SLACK_WEBHOOK_URL` にフォールバック |
| `SLACK_ALERT_WEBHOOK_URL` | enrichment カバレッジアラート（`check_enrichment_health.py`） | `SLACK_WEBHOOK_URL` にフォールバック |

> スクレイパー健全性アラート・建物名データ品質アラートを物件更新とは別チャンネルへ投稿したい場合は、そのチャンネル向けの Webhook を `SLACK_HEALTH_WEBHOOK_URL` に設定してください（`slack_notify.py` の `_send_health_alerts`）。

## 2.5 削除物件をスレッド返信にする（任意・Bot トークン）

既定では削除物件は本文の中にまとめて表示されます。**削除物件ブロックを本文のスレッド返信として
ぶら下げたい**場合は、Incoming Webhook ではなく **Slack Web API（`chat.postMessage`）** が必要です
（Webhook はメッセージの `ts` を返さず、スレッド返信ができないため）。

設定すると次の挙動になります:

- 本文（新規・入れ替え・値下げ・AI ダイジェスト）をトップレベル投稿
- 「❌ 削除された物件」の明細を**その投稿のスレッド返信**として送信（本文には件数サマリーのみ残る）
- Bot トークン未設定時は**従来通り**1通にインライン表示（後方互換・フォールバック）

### 手順

1. **Bot Token Scopes を追加**
   - https://api.slack.com/apps で対象アプリを開く
   - 「OAuth & Permissions」→「Scopes」→「Bot Token Scopes」に **`chat:write`** を追加
2. **ワークスペースにインストール（再インストール）**
   - 同ページ上部「Install to Workspace」/「Reinstall to Workspace」
   - 表示される **Bot User OAuth Token**（`xoxb-...`）をコピー
3. **Bot を投稿先チャンネルに招待**
   - 対象チャンネルで `/invite @real-estate-notifier`（アプリ名）を実行
4. **チャンネル ID を取得**
   - チャンネル名をクリック →「チャンネル詳細」最下部の ID（`C0XXXXXXX`）をコピー
   - ※ **Webhook と同じチャンネル**を指す ID にすること（投稿先がずれないように）
5. **GitHub Secrets に登録**
   - `SLACK_BOT_TOKEN` = `xoxb-...`
   - `SLACK_CHANNEL_ID` = `C0XXXXXXX`

> `SLACK_WEBHOOK_URL` はそのまま残してください（未設定だと通知自体がスキップされます。
> Bot トークン未設定時のフォールバック送信にも使われます）。`SLACK_BOT_TOKEN` と
> `SLACK_CHANNEL_ID` の**両方**が揃ったときだけスレッド返信モードになります。

## 3. 投稿する物件のフィルタ条件

Slack に投稿されるのは **資産性ランクが B 以上（S/A/B）の物件のみ** です。

- **ランクの算出**: 10年後の値上がり試算（price_predictor）と**共通アルゴリズム**を使用。**含み益率**（10年後Standard価格 − 10年後ローン残債）／現在成約推定価格で判定。
- **S**: 含み益率10%以上 / **A**: 5%以上 / **B**: 0%以上 / **C**: 0%未満
- 一覧に載る物件・「新規追加」「削除」「価格変動」のいずれも、この S/A/B に絞った結果のみ表示

**実装上の注意**: `slack_notify.py` は **generate_report に依存しません**。資産性・10年後予測・通勤時間等は `optional_features.py` 経由で利用しています。`SLACK_WEBHOOK_URL` が未設定の場合は警告ののち exit 0 でスキップします。

**投稿のタイミング**:
- **前回と今回で差分がない場合**（資産性B以上の新規・削除・価格変動が1件もない）→ **投稿はスキップ**
- **差分がある場合** → 冒頭に「■ 今回の変更」（新規追加・削除・価格変動の件数）を出したうえで、該当物件を投稿

**差分の判定**: 同一物件は **identity_key**（名前・間取り・広さ・住所・築年・駅徒歩。価格は除く）で判定します。価格だけ変わった場合は **価格変動** としてカウントされ、新規/削除にはなりません。

## 4. 動作確認

次回のワークフロー実行時（または手動実行時）に、変更があれば Slack に通知が送信されます。

**通知内容**（変更がある場合）:
- ■ 今回の変更（新規追加・削除・価格変動の件数）
- 🆕 新規追加された物件（最大10件）
- ❌ 削除された物件（最大5件）
- 🔄 価格変動した物件（最大5件、差額が大きい順）
- 📋 物件一覧（区・駅別、資産性B以上）
- 📄 レポートへのリンク

## 5. トラブルシューティング

### 通知が来ない

1. **GitHub Secrets を確認**
   - Settings → Secrets → `SLACK_WEBHOOK_URL` が正しく設定されているか

2. **ワークフローのログを確認**
   - Actions タブ → 実行履歴 → 「Send Slack notification」ステップ
   - エラーメッセージを確認

3. **Webhook URL の有効性を確認**
   - 以下のコマンドでテスト（ローカル環境）:
     ```bash
     curl -X POST -H 'Content-type: application/json' \
       --data '{"text":"テスト通知"}' \
       YOUR_WEBHOOK_URL
     ```

### 通知を一時的に無効化

`SLACK_WEBHOOK_URL` を GitHub Secrets から削除すると、通知はスキップされます（エラーにはなりません）。
