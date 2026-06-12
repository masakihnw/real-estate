# 画像ストレージの Cloudflare R2 移行ガイド

## 背景

Supabase Free プランの Storage 上限（1GB）に対し、`listing-images` バケットが
4GB 超（物件画像 + 間取り図、約4万ファイル）まで膨らみ、Fair Use Policy の
警告を受けた。画像の保存先を Cloudflare R2（無料枠 10GB・配信転送量無料）へ
移行し、あわせて不要画像の定期 GC を導入する。

- DB・認証・REST API は Supabase のまま（iOS アプリはコード変更なし。
  画像 URL はすべて `enrichments` 経由で配布されるため）
- アップロード経路は `upload_floor_plans.py` のまま（保存先だけ R2 に切替）

## 構成

| ファイル | 役割 |
|---|---|
| `scraping-tool/image_storage.py` | ストレージバックエンド抽象化。`R2_*` 環境変数があれば R2、なければ Supabase |
| `scraping-tool/storage_gc.py` | GC の純粋ロジック（テスト対象） |
| `scraping-tool/scripts/storage_image_gc.py` | 不要画像 GC の CLI（孤児 + 掲載終了物件の画像を削除） |
| `scraping-tool/scripts/migrate_storage_to_r2.py` | Supabase → R2 の移行 CLI |
| `.github/workflows/storage-image-gc.yml` | GC の定期実行（週次 + 手動） |

## 必要な環境変数 / GitHub Secrets

| 名前 | 値 |
|---|---|
| `R2_ENDPOINT_URL` | `https://<account_id>.r2.cloudflarestorage.com` |
| `R2_ACCESS_KEY_ID` | R2 API トークンのアクセスキー |
| `R2_SECRET_ACCESS_KEY` | R2 API トークンのシークレット |
| `R2_BUCKET_NAME` | バケット名（例: `listing-images`） |
| `R2_PUBLIC_BASE_URL` | 公開ベース URL（例: `https://pub-xxxx.r2.dev`。末尾スラッシュなし） |

## Cloudflare 側の準備（手動・1回のみ）

1. Cloudflare アカウントを作成し、ダッシュボードで R2 を有効化
   （支払い方法の登録が必要。無料枠内なら請求は発生しない）。
2. バケット `listing-images` を作成（ロケーション: Asia-Pacific 推奨）。
3. バケットの **Settings → Public access → R2.dev subdomain** を有効化し、
   表示される `https://pub-xxxx.r2.dev` を `R2_PUBLIC_BASE_URL` に使う。
   （独自ドメインを割り当てる場合はそちらのベース URL を使う）
4. **R2 API トークン**（Object Read & Write、対象バケット限定）を発行。
5. 上記5つを GitHub リポジトリの Actions Secrets に登録する。

## 移行手順

実行はスクレイピングパイプラインが動いていない時間帯に行う。
`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` / `R2_*` を環境変数に設定した上で:

```bash
cd scraping-tool

# 0. 不要画像の GC（孤児 + 掲載終了物件の画像 ≒ 1.4GB を先に削除）
python3 scripts/storage_image_gc.py            # dry-run で件数確認
python3 scripts/storage_image_gc.py --execute  # マニフェスト剪定も行うので変更をコミット

# 1. 全オブジェクトを R2 へコピー（中断しても再実行で続きから）
python3 scripts/migrate_storage_to_r2.py --phase copy

# 2. 件数・サイズの一致を検証（未移行 0 件になるまで copy を繰り返す）
python3 scripts/migrate_storage_to_r2.py --phase verify

# 3. URL の書き換え（DB の enrichments + マニフェスト + ローカル JSON）
python3 scripts/migrate_storage_to_r2.py --phase rewrite \
    --rewrite-file results/latest.json          # 存在しない場合はスキップされる
python3 scripts/migrate_storage_to_r2.py --phase rewrite \
    --rewrite-file results/latest.json --execute
# → 書き換わったマニフェストをコミットする

# 4. パイプラインを1サイクル（scrape → enrich → finalize）流し、
#    アプリで画像表示を確認する。
#    ※ 旧 URL を含む実行中アーティファクトが DB に再アップサートされる
#      余地を消すため、1サイクル置いてから次へ進む。

# 5. Supabase 側のオブジェクトを削除（容量解放。R2 に存在するものだけ消す）
python3 scripts/migrate_storage_to_r2.py --phase delete-source
python3 scripts/migrate_storage_to_r2.py --phase delete-source --execute
```

手順 3 のあと、旧 Supabase URL が残っていないかは次で確認できる:

```sql
select count(*) from enrichments
where suumo_images::text like '%supabase.co/storage%'
   or floor_plan_images::text like '%supabase.co/storage%'
   or best_thumbnail_url like '%supabase.co/storage%';
```

## 移行後の運用

- GitHub Secrets に `R2_*` が登録されていれば、finalize の
  `upload_floor_plans.py` は自動的に R2 へアップロードする
  （`image_storage.r2_configured()` で判定）。
- `storage-image-gc.yml` が週次（月曜 4:00 JST）で不要画像を削除する。
  フェイルセーフ:
  - 削除比率が全体の 60% を超える場合は中止（取得失敗の疑い）
  - 直近 24 時間以内に作成されたオブジェクトは削除しない
    （enrichments 未反映の新規アップロードを保護）
  - listings / enrichments の取得が空・active 参照 0 件なら中止
- 掲載終了物件の画像は GC が削除し、enrichments の参照とマニフェストの
  エントリも同時に除去する。再掲載された場合は次回パイプラインで
  再アップロードされる。

## ロールバック

手順 5（delete-source）を実行するまでは Supabase 側に全ファイルが残っている。
問題が出た場合は rewrite を逆向き（R2 ベース URL → Supabase ベース URL の
文字列置換）に流せば戻せる。delete-source 実行後は R2 が唯一のコピーになる。
