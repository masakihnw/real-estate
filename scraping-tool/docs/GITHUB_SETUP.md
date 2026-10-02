# GitHub Actionsのセットアップガイド

物件情報を GitHub Actions で自動更新するためのセットアップ手順です。

## ワークフローの構成

更新は2つのワークフローで行います。どちらもリポジトリルートの `.github/workflows/` にあります。

| ワークフロー | ファイル | 役割 |
|---|---|---|
| Scrape Listings（WF1） | `scrape-listings.yml` | 中古物件を取得し、前回結果との変更有無を判定する。結果はartifactでWF2に渡す |
| Enrich and Report（WF2） | `enrich-and-report.yml` | Scrape Listings が成功すると自動で起動する。enrich、レポート作成、Slack通知、コミットとプッシュを行う |

## セットアップ手順

### 1. ワークフローをリポジトリに入れる

`.github/workflows/` の2ファイルをGitHubのリポジトリに入れる作業です。`main` はブランチ保護のため、直接pushできません。ブランチを切ってPRを作成し、必須チェックの `ci-gate` が緑になってからマージしてください。

### 2. GitHub Actionsの確認

1. GitHubリポジトリの Actions タブを開きます。
2. 左サイドバーに "Scrape Listings" と "Enrich and Report" が表示されることを確認します。
3. 初回は、手動実行でテストできます（"Run workflow" ボタン）。

### 3. 動作確認

- 初回実行は、Actions タブで "Scrape Listings" を選び、"Run workflow" を押します。成功すると "Enrich and Report" が続けて起動します。
- 実行ログは、実行中のワークフローをクリックして確認します。
- 結果は、`scraping-tool/results/` にファイルが追加されていることで確認します。

## スケジュールと動作

- 実行頻度は1日4回です。
  Scrape Listings は JST 9:00、15:00、18:00、20:00（UTC 0:00、6:00、9:00、11:00）に起動します。
- Slack通知は、2026-07-07から全経路で停止しています。`slack_notify.py` は、環境変数 `SLACK_NOTIFICATIONS_ENABLED=1` を設定したときだけ送信します。ワークフローはこの変数を設定していないため、現在は届きません。再開後の送信は、UTC 0〜5時に開始した回だけです（JST 9:00の回に当たります）。GitHub Actions のcronは数時間遅れることがあるため、UTC 0〜5時を通知の時間帯にしています。
- 変更があったときだけ、WF2 の enrich、レポート作成、コミットとプッシュを行います。変更がなければ、スクレイピングと変更判定だけで終わります。ただし、通知の時間帯の回は、変更がなくても finalize ジョブが動き、未送信の通知を送ります。

スケジュールを変える場合は、`.github/workflows/scrape-listings.yml` の `cron` を編集します。

- `cron: '0 0,6,9,11 * * *'` は1日4回で、現在の設定です。
- `cron: '0 23 * * *'` は毎日 JST 8:00 の1回のみです。
- `cron: '0 * * * *'` は毎時0分です。サイトへの負荷が増えるため、推奨しません。

## トラブルシューティング

### コミットや通知が作成されない

- 物件に変更（新規、価格変動、削除）がない場合、WF2 のレポート作成とコミットは行いません。これは正常な動作です。
- Scrape Listings のログに `中古: 変更なし` と出る場合や、`has_changes: false` と出る場合は、前回と同じ結果です。

### プッシュが失敗する

`main` はブランチ保護で、必須チェックは `ci-gate`、直接pushは禁止です。
`github-actions[bot]` は管理者ではないので、`GITHUB_TOKEN` でpushすると `GH006` で拒否されます。
WF2の「Commit and push」ステップは、Secret `PAT_FINALIZE_PUSH` に入れた管理者用のPersonal Access Tokenでpushする設定です。
Secretが未設定だと `GITHUB_TOKEN` にフォールバックします。この場合、checkoutは通っても、pushだけが失敗します。

確認する点は次のとおりです。

1. Secret `PAT_FINALIZE_PUSH` が設定されていて、トークンが失効していないことを確認します。
2. 失敗したrunの "Commit and push" ステップを開き、赤いエラー行を確認します。
   - `protected branch` や `refusing to allow` と出る場合は、ブランチ保護がpushを止めています。
   - `Permission denied` と出る場合は、権限かトークンに問題があります。
3. `git exit code 128` で失敗する場合は、次の手順で設定を変えます。
   - リポジトリの Settings、Actions、General、Workflow permissions で "Read and write permissions" を選び、Save で保存します。
   - 変更するのは、ワークフローが置かれているリポジトリの設定です。親リポジトリのサブフォルダとして含まれている場合は、親リポジトリの設定になります。
4. フォークしたリポジトリでは、デフォルトブランチへのpushが制限されている場合があります。親リポジトリへPRを出すか、独立したリポジトリで実行してください。

### 実行がスキップされる

- リポジトリがフォークの場合、スケジュール実行はデフォルトで無効です。
- Settings、Actions、General で有効化してください。

## 手動実行

ローカル環境から手動で実行する場合は、次のコマンドを使います。

```bash
cd scraping-tool
./scripts/update_listings.sh
```

Git操作をスキップする場合は、次のコマンドを使います。

```bash
./scripts/update_listings.sh --no-git
```
