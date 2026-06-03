# ワンショット: HOME'S 画像バックフィル

- **実行方法**: GitHub Actions `backfill-homes-images` ワークフローを手動トリガー
- **所要時間目安**: 対象件数 × 10秒（WAFリトライ含め最大3時間）

---

## 概要

DB上の HOME'S 物件で画像（suumo_images）が未登録の全物件に対し、
Playwright（ヘッドレスブラウザ）で詳細ページを取得し、画像を抽出して enrichments テーブルに書き込む。

**Claude ルーティンからは実行不可**（クラウドコンテナのネットワーク許可リストに homes.co.jp が含まれないため）。
GitHub Actions 経由で実行する。

---

## 実行方法

### GitHub Actions（推奨）

1. GitHub リポジトリの **Actions** タブを開く
2. **Backfill HOME'S Images** ワークフローを選択
3. **Run workflow** をクリック
4. パラメータ:
   - `limit`: 処理上限件数（0=全件、デフォルト0）
   - `delay`: リクエスト間隔秒（デフォルト8）
5. 実行開始 → ログは Actions タブで確認

### ローカル実行（Mac）

```bash
cd /Users/pg000080/dev/personal/real-estate-public/scraping-tool
export SUPABASE_SERVICE_ROLE_KEY="<your-key>"
python3 homes_image_backfill.py --delay 8
```

---

## 技術詳細

ワークフロー: `.github/workflows/backfill-homes-images.yml`

1. `listing_facts` ビューから `suumo_images IS NULL` の homes 物件を取得
2. Playwright Chromium でページ取得（WAF の JS チャレンジを突破）
3. BeautifulSoup で画像URL解析（物件写真 + 間取り図を分離）
4. `enrichments` テーブルに upsert（空配列での上書き防止つき）
5. WAF 連続5回で安全に中断

---

## 共通ルール

- WAF 連続5回で全体中断
- ページ間の間隔はデフォルト8秒
- `enrichments` テーブルへの書き込みは `listing_facts` ビューに即座に反映される
