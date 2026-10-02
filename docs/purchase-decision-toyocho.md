# 購入決定メモ パークホームズ東陽町キャナルアリーナ 16F

> このリポジトリは中古マンションを探して買うための探索パイプラインである。購入物件がほぼ確定したため、探索フェーズから購入・入居準備フェーズへ移行する。本メモはその記録である。
>
> 最終更新は2026-07-07。申込済み・契約前の暫定情報であり、日付と金額は仮のものを含む。この日付以降の契約・引き渡しの状況は本メモに反映していない。

## 概要

| 項目 | 内容 |
|------|------|
| 物件名 | パークホームズ東陽町キャナルアリーナ |
| 所在階 | 16F |
| 価格 | 1億180万円 |
| 状況 | 申込済み。特段の問題がなければ2週間以内に契約予定 |
| 契約日（仮） | 2026-07-20 |
| 引き渡し（仮） | 2026年10月末 |
| 入居見込み | 2026年11月ごろ（引き渡し後、軽リフォームを終えてから） |

## スケジュール（暫定）

```
2026-07 申込済み → 2週間以内に契約（契約日 仮 7/20）
   ↓
2026-10末 引き渡し（仮）
   ↓
2026-10〜11 軽リフォーム（下記）
   ↓
2026-11ごろ 入居見込み
```

## リフォーム（引き渡し後・入居前）

軽めのリフォームを想定しており、見積もりは概算で約100万円である。

- 床のリペア
- 壁のリペア
- 給湯器の交換
- 風呂栓の交換（できれば）
- コンセント増設（必要に応じて）

## 売主残置設備

引き渡し時に売主が残していく設備を次に示す。寝室のエアコンは今回追加で交渉した。

- リビングのエアコン
- 寝室のエアコン（今回追加）
- カップボード
- キッチンカウンター下の棚
- カーテン

## 新たに購入・追加する家具・機器

- ダイニングテーブルとチェア
- ソファ
- IoT機器（一式）

## 住宅ローン審査状況

| 金融機関 | 仮審査 |
|----------|--------|
| PayPay銀行 | 通過 |
| SBI新生銀行 | 通過 |
| 静岡銀行 | 審査中 |

各行の条件比較は [loan-bank-candidates.md](./loan-bank-candidates.md) にまとめている。

## 運用 物件Slack通知の一時停止（2026-07）

購入がほぼ確定し、物件探索のSlack通知は不要になったため、すべて一時停止した。データ取得パイプライン、enrichment、AI分析、Claudeルーティンは従来どおり継続している。止めているのは送信だけである。

### 停止した内容

1. Python経由の全Slack送信（本通知、健全性アラート、通知ドラフト）
   - `scraping-tool/slack_notify.py` に一元スイッチ `slack_notifications_enabled()` を追加した。既定では無効である。Slackへ実際にPOSTする次の2つの低レベル送信関数を、このスイッチで両方とも遮断する。
     - `send_slack_message()`（Incoming Webhook経路）
     - `send_slack_via_web_api()`（Botトークンの `chat.postMessage` 経路。スレッド返信モードで、`SLACK_BOT_TOKEN` と `SLACK_CHANNEL_ID` を設定したときの主な送信経路）
   - 停止中は実際のPOSTを行わず、成功として扱う。そのため通知ドラフトはpendingに滞留せず、`notification-watchdog` の誤検知も起きない。
   - `slack-smoke-test.yml`（手動実行のみ）も `send_slack_via_web_api` を使う。停止中は実送信されない。
2. GitHub Actionsのcurl直送通知5ステップを `if: false` で無効化した。
   - `enrich-and-report.yml`（失敗通知）
   - `scrape-listings.yml`（失敗通知）
   - `update-reinfolib-cache.yml`（新着通知と失敗通知）
   - `supabase-backup.yml`（失敗通知、`SLACK_ALERT_WEBHOOK_URL` を使用）

### 継続しているもの

- スクレイピング、enrichment、AI分析（SupabaseとiOSアプリへの反映）
- Claudeルーティン（`.claude/routines/`）

`notification-watchdog.yml` はSlackではなくGitHub Issueで通知するため、Slack停止の時点では止める必要がなかった。このワークフローは2026-07-08に別の理由で無効化している。経緯は次の節に書く。

### 停止の副作用

- パイプライン障害時のSlack失敗通知も止まる。障害はGitHub Actionsの実行履歴で検知する。
- リポジトリ外のクラウドエージェントやスケジュール実行がSlackへ直接投稿している場合、この変更では止まらない。別途停止が必要である。

### 通知を再開するには

1. 環境変数 `SLACK_NOTIFICATIONS_ENABLED=1` を設定する。設定先はGitHub Actionsのfinalizeジョブのenvか、ローカル実行時の環境である。代わりに、`slack_notifications_enabled()` の既定値を `"1"` に戻してもよい。
2. 上の5ステップの `if: false` を元の条件（`if: failure()`、または `if: steps.commit.outputs.has_changes == 'true'`）に戻す。元の条件は各ステップのコメントに書いてある。

## 運用 GitHub Actionsの失敗メール抑制（2026-07-08）

上のSlack停止とは別件である。GitHub Actionsから失敗メールが多数届くようになったため、失敗していた4本のワークフローを `gh workflow disable` で無効化した。コード変更とpushは伴わず、GitHub側の実行状態だけを変更している。

### 経緯と原因

- 失敗メールを出していたのはこの4本だけである。いずれもSupabaseへの接続に失敗していた。エラーはDNS解決エラー `Name or service not known`（curl exit 6）である。Slack通知停止（#100）とは無関係の別の障害である。
- 同じ `SUPABASE_URL` を使う `enrich-and-report`、`scrape-listings`、`enrich-sumai` は成功しており、データ収集パイプライン本体は稼働を続けている（40分ごとに `Update listings` をコミットしている）。この4本だけがSupabaseに到達できない原因は未調査で、再開するときに調べる必要がある。

### 無効化した4本

| ワークフロー | ID | トリガ | 役割 |
|---|---|---|---|
| Notification Watchdog | 291179546 | schedule | 通知滞留の監視 |
| Cron Watchdog | 305110002 | schedule | cron健全性の監視 |
| Detect Delisted Listings | 288389568 | Enrich and Reportの完了後（workflow_run） | 掲載終了検出 |
| Backfill HOME'S Images | 288375909 | schedule、Enrich and Reportの完了後 | 画像補完 |

2026-10-02に `gh workflow list --all` で確認した時点でも、4本とも `disabled_manually` である。

### 把握しておくこと

- 無効化はリポジトリのコードに記録されない。GitHub側の状態だけが変わるため、本ドキュメントが唯一の記録である。
- 掲載終了検出、画像補完、監視が止まっている。データ収集自体は続くが、掲載終了した物件がDBに残り続け、新規画像は補完されない。

### 再開するには

先にSupabaseに接続できない原因を解消してから、次を実行する。

```bash
cd ~/dev/personal/real-estate-public
gh workflow enable 291179546   # Notification Watchdog
gh workflow enable 305110002   # Cron Watchdog
gh workflow enable 288389568   # Detect Delisted Listings
gh workflow enable 288375909   # Backfill HOME'S Images
```
