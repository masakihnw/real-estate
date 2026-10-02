# 画像ストレージのCloudflare R2移行ガイド

## 背景

Supabase Freeプランの Storage 上限は1GBです。`listing-images` バケットが、物件画像と間取り図を合わせて4GB超（約4万ファイル）まで増え、Fair Use Policy の警告を受けました。そこで画像の保存先を Cloudflare R2（無料枠10GB、配信転送量は無料）へ移し、不要画像を定期的に削除するGCを導入しました。

- DB、認証、REST APIはSupabaseのままです。画像URLはすべて `enrichments` 経由で配布されるため、iOSアプリのコードは変更していません。
- アップロードの経路は `upload_floor_plans.py` のままです。保存先だけをR2に切り替えました。

## 構成

| ファイル | 役割 |
|---|---|
| `scraping-tool/image_storage.py` | ストレージバックエンドの抽象化。`R2_*` 環境変数が揃っていればR2、なければSupabaseを使う |
| `scraping-tool/storage_gc.py` | GCの純粋ロジック（テスト対象） |
| `scraping-tool/scripts/storage_image_gc.py` | 不要画像GCのCLI。孤児と、掲載終了物件だけが参照する画像を削除する |
| `scraping-tool/scripts/migrate_storage_to_r2.py` | SupabaseからR2への移行CLI |
| `.github/workflows/storage-image-gc.yml` | GCの定期実行（週次と手動） |
| `.github/workflows/storage-r2-migrate.yml` | 移行CLIをGitHub Actionsから手動実行する。フェーズと `execute` を入力で選ぶ |

## 必要な環境変数とGitHub Secrets

| 名前 | 値 |
|---|---|
| `R2_ENDPOINT_URL` | `https://<account_id>.r2.cloudflarestorage.com` |
| `R2_ACCESS_KEY_ID` | R2 APIトークンのアクセスキー |
| `R2_SECRET_ACCESS_KEY` | R2 APIトークンのシークレット |
| `R2_BUCKET_NAME` | バケット名（例: `listing-images`） |
| `R2_PUBLIC_BASE_URL` | 公開ベースURL（例: `https://pub-xxxx.r2.dev`。末尾のスラッシュは付けない） |

## Cloudflare側の準備（手動で1回だけ）

1. Cloudflareアカウントを作成し、ダッシュボードでR2を有効化します。支払い方法の登録が必要です。無料枠内であれば請求は発生しません。
2. バケット `listing-images` を作成します。ロケーションはAsia-Pacificを推奨します。
3. バケットの Settings、Public access、R2.dev subdomain を有効化します。表示された `https://pub-xxxx.r2.dev` を `R2_PUBLIC_BASE_URL` に使います。独自ドメインを割り当てる場合は、そのベースURLを使います。
4. R2 APIトークンを発行します。権限はObject Read & Write、対象はこのバケットだけにします。
5. 上記の5つをGitHubリポジトリのActions Secretsに登録します。

## 移行手順

実行は、スクレイピングパイプラインが動いていない時間帯に行います。`SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY`、`R2_*` を環境変数に設定した上で、次のコマンドを順に実行してください。GitHub Actionsの「Storage R2 Migration」ワークフローでも、同じフェーズを実行できます。

```bash
cd scraping-tool

# 0. 不要画像のGC（孤児と掲載終了物件の画像、約1.4GBを先に削除）
python3 scripts/storage_image_gc.py            # dry-runで件数を確認
python3 scripts/storage_image_gc.py --execute  # マニフェストの剪定も行うので、変更をコミットする

# 1. 全オブジェクトをR2へコピー（中断しても再実行で続きから）
python3 scripts/migrate_storage_to_r2.py --phase copy

# 2. 件数とサイズの一致を検証（未移行が0件になるまでcopyを繰り返す）
python3 scripts/migrate_storage_to_r2.py --phase verify

# 3. URLの書き換え（DBのenrichments、マニフェスト、ローカルJSON）
python3 scripts/migrate_storage_to_r2.py --phase rewrite \
    --rewrite-file results/latest.json          # 存在しない場合はスキップされる
python3 scripts/migrate_storage_to_r2.py --phase rewrite \
    --rewrite-file results/latest.json --execute
# 書き換わったマニフェストをコミットする

# 4. パイプラインを1サイクル（scrape、enrich、finalize）流し、
#    アプリで画像が表示されることを確認する。
#    旧URLを含む実行中のアーティファクトがDBに再アップサートされる余地を
#    なくすため、1サイクル置いてから次へ進む。

# 5. Supabase側のオブジェクトを削除（容量を解放する。R2に存在するものだけ削除する）
python3 scripts/migrate_storage_to_r2.py --phase delete-source
python3 scripts/migrate_storage_to_r2.py --phase delete-source --execute
```

手順3のあと、旧SupabaseのURLが残っていないかは、次のSQLで確認できます。

```sql
select count(*) from enrichments
where suumo_images::text like '%supabase.co/storage%'
   or image_categories::text like '%supabase.co/storage%'
   or floor_plan_images::text like '%supabase.co/storage%'
   or best_thumbnail_url like '%supabase.co/storage%';
```

過去の移行では `image_categories` 列が書き換えの対象から漏れ、GCもこの列を参照として数えていませんでした。そのため、URLが旧Supabaseのまま残るエントリや、実体がGC済みでR2に存在しないエントリが生じている場合があります。その修復には、`--phase recover-image-categories` を使います。R2に実在するオブジェクトは、URLをR2へ書き換えます。R2に無いオブジェクトは、エントリを削除します。`--execute` を付けたときだけ変更を行います。

## 移行後の運用

- GitHub Secretsに `R2_*` が登録されていれば、finalizeの `upload_floor_plans.py` は自動でR2へアップロードします（`image_storage.r2_configured()` で判定します）。
- `storage-image-gc.yml` が、毎週月曜の4:00 JSTに不要画像を削除します。手動実行では、対象のバックエンドを `auto`、`supabase`、`r2` から選べます。`auto` はR2が設定済みならR2を対象にします。次のフェイルセーフがあります。
  - 削除比率が全体の60%を超える場合は中止します。取得失敗を疑うためです。
  - 直近24時間以内に作成されたオブジェクトは削除しません。enrichmentsに未反映の新規アップロードを守るためです。
  - listingsとenrichmentsの取得が空の場合と、activeな参照が0件の場合は中止します。
- 掲載終了物件の画像は、GCが削除します。同時に、enrichmentsの参照とマニフェストのエントリも除去します。再掲載された場合は、次回のパイプラインで再アップロードします。

## ロールバック

手順5（delete-source）を実行するまでは、Supabase側に全ファイルが残っています。問題が出た場合は、rewriteを逆向きに流せば戻せます。R2のベースURLをSupabaseのベースURLへ、文字列で置換します。delete-sourceを実行した後は、R2が唯一のコピーになります。
