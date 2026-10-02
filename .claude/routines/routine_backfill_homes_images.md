# ワンショット: HOME'S画像バックフィル

- 実行方法: GitHub Actions `backfill-homes-images`ワークフローを手動で起動する。ワークフローは毎日JST 4:30と、`Enrich and Report`の成功後にも自動で実行される
- 所要時間目安: 対象件数 × 10秒。ワークフローの`timeout-minutes`は60分

---

## 概要

DB上のHOME'S物件のうち、画像（suumo_images）が未登録の全物件が対象である。
Playwright（ヘッドレスブラウザ）で詳細ページを取得し、画像を抽出する。抽出した画像はenrichmentsテーブルに書き込む。

Claudeルーティンからは実行できない。クラウドコンテナのネットワーク許可リストにhomes.co.jpが含まれないためである。
GitHub Actions経由で実行する。

---

## 実行方法

### GitHub Actions（推奨）

1. GitHubリポジトリのActionsタブを開く
2. Backfill HOME'S Imagesワークフローを選択する
3. Run workflowをクリックする
4. パラメータを入力する
   - `limit`: 処理上限件数（0は全件、手動実行の既定値は0）
   - `delay`: リクエスト間隔の秒数（手動実行の既定値は8）
5. 実行を開始し、ログはActionsタブで確認する

### ローカル実行（Mac）

```bash
cd /Users/pg000080/dev/personal/real-estate-public/scraping-tool
export SUPABASE_SERVICE_ROLE_KEY="<your-key>"
python3 homes_image_backfill.py --delay 8
```

---

## 技術詳細

ワークフロー: `.github/workflows/backfill-homes-images.yml`

1. `listing_facts`ビューから`suumo_images IS NULL`のhomes物件を取得
2. Playwright Chromiumでページを取得する（WAFのJSチャレンジを通過する）
3. BeautifulSoupで画像URLを解析する（物件写真と間取り図を分ける）
4. `enrichments`テーブルにupsertする（空配列では上書きしない）
5. WAFが連続5回になったら中断する

---

## 共通ルール

- ページ間の間隔は、手動実行の既定値が8秒
- `enrichments`テーブルへの書き込みは`listing_facts`ビューに即座に反映される
