# HOME'S 画像未取得問題の調査結果と対策案

2026-06-03時点の調査メモです。第2節のデータと第3節のコードの記述は、その時点のものです。調査後の実装状況は、末尾の「その後の実装状況」に書いています。

## 1. 問題概要

iOSアプリで画像が表示されない物件が多数ありました。調査の結果、HOME'S（LIFULL HOME'S）の物件で、画像がほとんど取得できていないことが分かりました。

---

## 2. 調査時点のデータ（Supabase `listing_facts` テーブル、2026-06-03時点）

### 2a. 媒体別の画像カバレッジ（アクティブ物件のみ）

| 媒体 | 物件数 | 画像あり | 画像率 | 間取り率 | 平均画像枚数 |
|------|--------|---------|--------|---------|------------|
| suumo | 388 | 374 | 96.4% | 96.4% | 23.8枚 |
| homes | 241 | 2 | 0.8% | 0.8% | 31.5枚（2件のみの平均） |
| rehouse | 81 | 81 | 100% | 100% | 8.8枚 |
| nomucom | 72 | 72 | 100% | 95.8% | 23.4枚 |
| livable | 50 | 50 | 100% | 100% | 30.3枚 |

### 2b. 補足データ

- homesの241件は、すべてhomes単独の掲載です（他媒体との重複はゼロ）。そのため、他媒体から画像を補えません。
- suumoの画像なし14件は、マイグレーション初期のデータ（`first_seen_source=null`）や古い物件が中心です。
- 画像なし物件の `first_seen_source` の内訳は、homes 226件、null 18件、suumo 9件です。

---

## 3. 根本原因の分析（2026-06-03時点のコード）

### 3a. コードレベルの問題

`homes_scraper.py` の問題は次のとおりです。

- `HomesListing` のdataclassに、`suumo_images` と `floor_plan_images` のフィールドがありません。
- 一覧ページからは、テキスト情報（名前、価格、住所、面積など）だけを取得しています。
- 画像を抽出する処理が一切ありません。

`floor_plan_enricher.py` の問題は次のとおりです。

- HOME'Sの詳細ページを訪問して、間取り図（`floor_plan_images`）だけを抽出していました。
- 物件写真（`suumo_images`。外観、内装、眺望など）には対応していませんでした。
- HTMLの取得、WAFの処理、キャッシュの仕組みは整っていました。

`main.py` の `_scrape_homes_chuko()` は、スクレイピングの後にenrichmentの関数を呼んでいませんでした。他の媒体は、すべて `enrich_*_listings()` で詳細ページから画像を取得しています。

### 3b. 他媒体との比較

| 媒体 | 一覧で画像取得 | 詳細ページenrich |
|------|--------------|-----------------|
| suumo | あり | あり（詳細キャッシュ経由） |
| athome | あり | あり（`enrich_athome_listings()`） |
| rehouse | なし | あり（`enrich_rehouse_listings()`） |
| nomucom | なし | あり（`enrich_nomucom_listings()`） |
| livable | なし | あり（`enrich_livable_listings()`） |
| homes | なし | 間取り図のみ |

### 3c. `floor_plan_enricher.py` だけでは足りなかった理由

`floor_plan_enricher.py` は、HOME'Sの詳細ページのHTMLを取得していますが、次の点で不足していました。

- `parse_homes_floor_plan_images()` は、間取り図だけを抽出します（alt="間取"、floorplanセクションなど）。
- 物件写真（外観、内装、リビング、キッチン、バス、眺望など）を無視しています。
- DBへの書き込みも、`floor_plan_images` フィールドだけです。

---

## 4. 対策案

### 案A: `floor_plan_enricher.py` を拡張する（推奨）

既存の `floor_plan_enricher.py` を拡張し、間取り図に加えて物件写真も抽出します。

メリットは次のとおりです。

- HTMLの取得、WAFの処理、キャッシュの仕組みを再利用できます。HOME'S詳細ページのHTMLキャッシュは、すでにあります。
- 詳細ページを1回訪問すれば、間取り図と物件写真を同時に取得できます。追加のリクエストは不要です。
- 変更する箇所が少なくて済みます。

実装内容は次のとおりです。

1. `parse_homes_property_images(html)` 関数を新規に作成します。
   - HOME'S詳細ページの物件写真ギャラリーから、画像URLとラベルを抽出します。
   - 間取り図は除外します（`floor_plan_enricher` が別に処理します）。
   - サイトUI用の画像（ロゴ、ボタン、アイコンなど）をフィルタで除きます。
2. `main()` を拡張し、`suumo_images` も同時に取得して書き込みます。
3. `enrichment_writer.write_enrichments()` に `suumo_images` を追加します。

想定工数は中程度で、既存コードの拡張で済みます。

### 案B: `homes_scraper.py` に `enrich_homes_listings()` を追加する

他媒体と同じパターンで、`homes_scraper.py` 内に `enrich_homes_listings()` を追加し、`main.py` から呼びます。

メリットは次のとおりです。

- 他媒体とアーキテクチャが揃います。
- `main.py` のパイプラインの流れが一貫します。

デメリットは次のとおりです。

- `floor_plan_enricher.py` のHTMLキャッシュと重複する仕組みを作ることになります。
- homesはWAFが厳しいです。一覧のスクレイピング直後に詳細ページも取得すると、レート制限を受けるリスクが高くなります。
- Playwrightが必要になる可能性があります。一覧ページはWAFのためPlaywrightが必須ですが、詳細ページはrequestsでも通った実績があります。

想定工数は大きく、新規関数、キャッシュの仕組み、`main.py` への統合が必要になる。

### 案C: `floor_plan_enricher` を `homes_image_enricher` に改名して全面拡張する

`floor_plan_enricher.py` を `homes_image_enricher.py` に改名し、間取り図と物件写真の両方を取得する汎用のenricherにします。

メリットは次のとおりです。

- 責務が明確になります（HOME'Sの画像全般を担当します）。
- 将来、homes固有の画像処理をここに集約できます。

デメリットは次のとおりです。

- 既存の呼び出し元（パイプライン、ルーティンなど）の変更が必要です。
- `floor_plan_enricher` の名前で参照している箇所を、すべて更新する必要があります。

想定工数は中から大きめと見ていました。

---

## 5. 推奨は案A（`floor_plan_enricher.py` の拡張）

### 理由

1. 既存のHTML取得とキャッシュの仕組みを、そのまま使えます。
2. 追加のリクエストが不要です。キャッシュ済みのHTMLから、物件写真を抽出するだけで済みます。
3. 新しいHTTPリクエストを増やさないため、WAFのリスクが低くなります。
4. 既存のキャッシュがあれば、再スクレイピングなしで画像を取得できます。

### 実装ステップ

1. `parse_homes_property_images(html)` を実装します（HOME'S詳細ページの画像ギャラリーの解析）。
2. `floor_plan_enricher.py` の `main()` を拡張し、`suumo_images` も処理します。
3. `enrichment_writer.py` で、`suumo_images` を `listing_facts` に書き込みます。
4. 既存のキャッシュで動作を確認し、続けて新規取得した物件でも確認します。
5. suumoの画像なし14件についても、別に調査して対応します。

### 期待効果

- homesの画像率は、0.8%から80%以上になる見込みです（詳細ページに画像ギャラリーがあることが前提です）。
- 全体の画像なし物件は、約253件から30件以下になる見込みです。

---

## 6. suumoの画像なし物件（14件）について

| 件数 | 原因 | 対応 |
|------|------|------|
| 4件 | `first_seen_source=null`（マイグレーション初期） | 再スクレイピングで自然に解消する見込み |
| 5件 | `first_seen_source=suumo`、`created_at` が古い | 詳細ページを再取得すれば解消できる |
| 5件 | `first_seen_source=suumo`、最近作成 | 一覧ページで画像が取れていない可能性があり、個別の調査が必要 |

suumoの14件の調査は、homesの対応が済んでからで十分です。

---

## その後の実装状況

案Aの内容は、コードに入っています。画像率の再計測は行っていないため、第2節の数値は更新していません。

- `floor_plan_enricher.py` に `parse_homes_property_images()` があります。`main()` は、間取り図と物件写真の両方を取得し、`write_enrichments(listings, ["floor_plan_images", "suumo_images"], "homes_images")` で書き込みます。
- `scripts/run_enrich.sh` の Track G が、`floor_plan_enricher.py` を `--limit 50` で実行します。
- 既存のhomes物件で `suumo_images` が未登録のものは、`homes_image_backfill.py` が詳細ページから取得します。取得した画像はenrichmentsに書き込みます。GitHub Actionsの `backfill-homes-images.yml` が、毎日JST 4:30と、`Enrich and Report` の成功後に実行します。
- `homes_scraper.py` の `HomesListing` には、現在も画像のフィールドがありません。
