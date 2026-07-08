# 購入決定メモ: パークホームズ東陽町キャナルアリーナ 16F

> このリポジトリは「中古マンションを探して買う」ための探索パイプラインだが、購入物件が
> ほぼ確定したため、探索フェーズから購入・入居準備フェーズへ移行する。本メモはその記録。
>
> **最終更新: 2026-07-07（申込済み・契約前の暫定情報。日付・金額は仮のものを含む）**

## 概要

| 項目 | 内容 |
|------|------|
| 物件名 | パークホームズ東陽町キャナルアリーナ |
| 所在階 | 16F |
| 価格 | 1億180万円 |
| 状況 | **申込済み。特段の問題がなければ2週間以内に契約予定。** |
| 契約日（仮） | **2026-07-20** |
| 引き渡し（仮） | **2026年10月末** |
| 入居見込み | **2026年11月ごろ**（引き渡し後、軽リフォームを終えてから） |

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

## リフォーム（引き渡し後・入居前／概算 約100万円）

軽めのリフォームを想定。概算 **ざっくり100万円** 程度の見積もり。

- 床のリペア
- 壁のリペア
- 給湯器の交換
- 風呂栓の交換（できれば）
- コンセント増設（必要に応じて）

## 売主残置設備（置いていってもらうもの）

引き渡し時に売主が残していく設備。**寝室のエアコンを今回追加**で交渉。

- リビングのエアコン
- **寝室のエアコン**（今回追加）
- カップボード
- キッチンカウンター下の棚
- カーテン

## 新たに購入・追加する家具・機器

- ダイニングテーブル + チェア
- ソファ
- IoT 機器（一式）

## 住宅ローン審査状況

| 金融機関 | 仮審査 |
|----------|--------|
| PayPay 銀行 | ✅ 通過 |
| SBI 新生銀行 | ✅ 通過 |
| 静岡銀行 | ⏳ 審査中 |

## 運用: 物件 Slack 通知の一時停止（2026-07）

購入がほぼ確定し、物件探索の Slack 通知は不要になったため **全て一時停止**した。
データ取得パイプライン・enrichment・AI 分析・Claude ルーティンは**従来どおり継続**する
（送信のみ止めている）。

### 停止した内容

1. **Python 経由の全 Slack 送信**（本通知・健全性アラート・通知ドラフト）
   - `scraping-tool/slack_notify.py` に一元スイッチ `slack_notifications_enabled()`（既定で無効）を追加し、
     Slack へ実 POST する**2つの低レベル送信関数の両方**を遮断:
     - `send_slack_message()`（Incoming Webhook 経路）
     - `send_slack_via_web_api()`（Bot トークン `chat.postMessage` 経路＝スレッド返信モード。
       `SLACK_BOT_TOKEN` + `SLACK_CHANNEL_ID` 設定時の主送信経路）
   - 停止中は実際の POST を行わず「成功」として扱うため、通知ドラフトは pending に滞留せず、
     `notification-watchdog` の誤検知も起きない。
   - `slack-smoke-test.yml`（手動実行のみ）も上記 `send_slack_via_web_api` を使うため、停止中は実送信されない。
2. **GitHub Actions の curl 直送通知（5ステップ）** を `if: false` で無効化。
   - `enrich-and-report.yml`（失敗通知）
   - `scrape-listings.yml`（失敗通知）
   - `update-reinfolib-cache.yml`（新着通知・失敗通知）
   - `supabase-backup.yml`（失敗通知 / `SLACK_ALERT_WEBHOOK_URL`）

### 継続しているもの

- スクレイピング／enrichment／AI 分析（Supabase・iOS アプリへの反映）
- Claude ルーティン（`.claude/routines/`）
- `notification-watchdog.yml`（Slack ではなく GitHub Issue で通知するため停止不要。
  通知ドラフトが滞留しなくなったので発火しない）

### ⚠️ 副作用（把握しておくこと）

- **パイプライン障害時の Slack 失敗通知も止まる。** 障害検知は GitHub Actions の実行履歴と
  `notification-watchdog`（GitHub Issue）で行う。
- **リポジトリ外**のクラウドエージェント／スケジュール実行が直接 Slack へ投稿している場合、
  本変更では止まらない（別途停止が必要）。

### 通知を再開するには

1. 環境変数 `SLACK_NOTIFICATIONS_ENABLED=1` を設定（GitHub Actions の finalize ジョブ env、
   またはローカル実行時）。または `slack_notifications_enabled()` の既定値を `"1"` に戻す。
2. 上記 5 ステップの `if: false` を元の条件（`if: failure()` /
   `if: steps.commit.outputs.has_changes == 'true'`）に戻す。各ステップにコメントで明記済み。

## 運用: GitHub Actions の失敗メール抑制（2026-07-08）

上記 Slack 停止とは**別件**。GitHub Actions から失敗メールが多数届くようになったため、
失敗していた 4 本のワークフローを **`gh workflow disable` で無効化**した
（コード変更・push は伴わない。GitHub 側の実行状態のみ変更）。

### 経緯・原因

- 失敗メールを出していたのはこの 4 本のみ。**いずれも Supabase への接続失敗**
  （DNS 解決エラー `Name or service not known` / curl exit 6）で落ちていた。
  Slack 通知停止（#100）とは無関係の別障害。
- 同じ `SUPABASE_URL` を使う `enrich-and-report` / `scrape-listings` / `enrich-sumai` は
  **成功**しており、データ収集パイプライン本体は稼働継続中（40 分ごとに `Update listings` をコミット）。
  この 4 本だけ Supabase に到達できない原因は未調査（再開時に要調査）。

### 無効化した 4 本

| ワークフロー | ID | トリガ | 役割 |
|---|---|---|---|
| Notification Watchdog | 291179546 | schedule | 通知滞留の監視 |
| Cron Watchdog | 305110002 | schedule | cron 健全性の監視 |
| Detect Delisted Listings | 288389568 | scrape 後（workflow_run） | 掲載終了検出 |
| Backfill HOME'S Images | 288375909 | schedule / scrape 後 | 画像補完 |

### ⚠️ 把握しておくこと

- 無効化はリポジトリのコードには記録されない（GitHub 側の状態のみ）。本ドキュメントが唯一の記録。
- 掲載終了検出・画像補完・監視が止まっている。データ収集自体は継続しているが、
  掲載終了物件が DB に残り続ける・新規画像が補完されない点に留意。

### 再開するには（先に Supabase 接続不可の原因を解消すること）

```bash
cd ~/dev/personal/real-estate-public
gh workflow enable 291179546   # Notification Watchdog
gh workflow enable 305110002   # Cron Watchdog
gh workflow enable 288389568   # Detect Delisted Listings
gh workflow enable 288375909   # Backfill HOME'S Images
```
