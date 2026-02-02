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
   - https://github.com/masakihnw/dev-workspace

2. **Settings → Secrets and variables → Actions** を開く

3. **「New repository secret」をクリック**
   - Name: `SLACK_WEBHOOK_URL`
   - Secret: 上記で取得した Webhook URL を貼り付け

4. **「Add secret」をクリック**

## 3. 投稿する物件のフィルタ条件

Slack に投稿されるのは **資産性ランクが B 以上（S/A/B）の物件のみ** です。

- **ランクの算出**: 10年後の値上がり試算（price_predictor）と**共通アルゴリズム**を使用。**含み益率**（10年後Standard価格 − 10年後ローン残債）／現在成約推定価格で判定。
- **S**: 含み益率10%以上 / **A**: 5%以上 / **B**: 0%以上 / **C**: 0%未満
- 一覧に載る物件・「新規追加」「削除」「価格変動」のいずれも、この S/A/B に絞った結果のみ表示

**投稿のタイミング**:
- **前回と今回で差分がない場合**（資産性B以上の新規・削除・価格変動が1件もない）→ **投稿はスキップ**
- **差分がある場合** → 冒頭に「■ 今回の変更」（新規追加・削除・価格変動の件数）を出したうえで、該当物件を投稿

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
