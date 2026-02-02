# GitHub Actions セットアップガイド

物件情報の自動更新をGitHub Actionsで行うためのセットアップ手順です。

## セットアップ手順

### 1. リポジトリにプッシュ

このリポジトリをGitHubにプッシュします：

```bash
git add .
git commit -m "Add GitHub Actions workflow for automatic listings update"
git push origin main
```

### 2. GitHub Actions の確認

1. GitHubリポジトリの **Actions** タブを開く
2. 左サイドバーに "Update Listings" ワークフローが表示されることを確認
3. 初回は手動実行でテスト可能（"Run workflow" ボタン）

### 3. 動作確認

- **初回実行**: Actions タブから "Run workflow" → "Run workflow" をクリック
- **実行ログ**: 実行中のワークフローをクリックしてログを確認
- **結果確認**: `scraping-tool/results/` にファイルが追加されていることを確認

## スケジュールと動作

- **実行頻度**: デフォルトで**毎日 1 回、JST 8:00**（UTC 23:00）。サイト負荷を抑えるため 1 日 1 回にしている。
- **変更時のみ**: 物件に新規・価格変動・削除があったときだけ、レポート作成・Slack通知・コミット・プッシュを行う。変更がなければスクレイピングのみ実行して終了。

スケジュールを変更する場合（リポジトリルートの `.github/workflows/update-listings.yml` を編集）：

- `cron: '0 23 * * *'` = 毎日 JST 8:00 のみ（**現在の設定**）
- `cron: '0 */2 * * *'` = 2時間ごと（JST 9:00, 11:00, ...）
- `cron: '0 * * * *'` = 毎時 0 分（負荷が増えるため推奨しない）

## トラブルシューティング

### コミット・通知が作成されない

- 物件に変更（新規・価格変動・削除）がない場合、レポート作成・Slack通知・コミットは行いません（正常動作）
- ログに「変更なし（レポート・通知をスキップ）」または "changed=false" と出る場合は、前回と同じ結果です

### プッシュが失敗する（git exit code 128）

**原因**: デフォルトの GITHUB_TOKEN は「読み取り専用」のため、ワークフローから `git push` できません。

**対処（必須）**: このワークフローが動いている **リポジトリ**（例: dev-workspace）で、以下を実施してください。

1. GitHub でそのリポジトリを開く
2. **Settings** → **Actions** → **General**
3. 下の方の **Workflow permissions** で  
   **「Read and write permissions」** を選択
4. **Save** で保存

※ real-estate がサブフォルダの場合は、親リポジトリ（ワークフローが置いてあるリポジトリ）の設定を変更します。

**Read and write にしているのに 128 になる場合**

1. **エラー本文を確認**  
   Actions → 失敗した run → 「Commit and push」ステップを開き、赤いエラー行を確認。  
   - `protected branch` / `refusing to allow` → ブランチ保護でブロックされている
   - `Permission denied` → 権限かトークンの問題

2. **ブランチ保護の確認**  
   Settings → Branches → Branch protection rules で `main` にルールがある場合：
   - **Restrict who can push to matching branches** が有効だと、GITHUB_TOKEN が許可されていないと push できないことがある
   - その場合は「Allow specified actors to bypass required pull requests」などでワークフローからの push を許可するか、このワークフロー用に `main` を保護対象外にする

3. **フォークの場合**  
   フォークしたリポジトリでは、デフォルトブランチへの push が制限されている場合がある。親リポジトリへ PR で出す運用にするか、自分の独立したリポジトリで実行する。

### 実行がスキップされる

- リポジトリがフォークの場合、デフォルトでスケジュール実行が無効
- Settings → Actions → General で有効化

## 手動実行

ローカル環境から手動で実行する場合：

```bash
cd scraping-tool
./scripts/update_listings.sh
```

Git操作をスキップする場合：

```bash
./scripts/update_listings.sh --no-git
```
