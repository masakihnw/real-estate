# スクレイピングツール

REINS以外の物件サイトから、10年住み替え前提の中古マンション条件を満たす物件を取得するツールです。条件は [../docs/10year-index-mansion-conditions-draft.md](../docs/10year-index-mansion-conditions-draft.md) を参照してください。取得した物件はdedupとenrichmentを経てSupabaseに同期します。Markdownレポートも出力します。

- 取得元: SUUMO、HOME'S、athome、rehouse、nomucom、stepon、livable。`main.py --source` で選べる。
- 既定で無効にしているスクレイパー: stepon、athome。理由はボット検知で取得できないことで、`config.py` の `DISABLED_SCRAPERS` に書いてある。環境変数 `DISABLED_SCRAPERS` で上書きできる。
- athomeは、利用規約でクローラー等による情報取得が明示的に禁止されている（[docs/terms-check.md](./docs/terms-check.md)）。
- REINS: 成約データは本ツールでは取得しない。手動でレインズマーケットインフォメーションを参照する。

パイプライン全体の構成とGitHub Actionsの実行時刻は、[../README.md](../README.md) にある。Commandsと開発規約は、[../.claude/CLAUDE.md](../.claude/CLAUDE.md) にある。このREADMEは、`scraping-tool/` 内のモジュールとコマンドの説明に絞る。

## フォルダ構成

```
scraping-tool/
├── README.md              # 本ファイル
├── requirements.txt       # Python 依存
├── config.py              # 条件フィルタの閾値、リクエスト間隔、DISABLED_SCRAPERS
├── main.py                # CLI エントリ（取得・3段階dedup・JSON出力）
├── suumo_scraper.py       # SUUMO
├── homes_scraper.py       # HOME'S
├── athome_scraper.py      # athome
├── rehouse_scraper.py     # rehouse
├── nomucom_scraper.py     # nomucom
├── stepon_scraper.py      # stepon
├── livable_scraper.py     # livable
├── scraper_common.py      # スクレイパー共通処理（EmptyParseGuard、セッション生成、フィルタ）
├── *_enricher.py          # 通勤・ハザード・e-Stat・reinfolib・住まいサーフィンなどの enrichment
├── claude_*.py            # Claude API による分析・dedup・画像分類
├── asset_score.py         # 資産性スコア・S/A/B/Cランク（含み益率ベース）
├── asset_simulation.py    # 10年シミュレーション（資産性試算用）
├── future_estate_predictor.py # 10年後価格予測（3シナリオ・収益還元・原価法ハイブリッド）
├── price_predictor.py     # 10年後成約価格予測（FutureEstatePredictor を利用、外部CSV利用）
├── loan_calc.py           # ローン月額試算（50年変動・諸経費込）
├── commute.py             # 通勤時間表示（通勤先2拠点 オフィスA/B）
├── supabase_sync.py       # Supabase への同期
├── check_changes.py       # 前回結果との差分有無判定（update_listings.sh で利用）
├── report_utils.py        # レポート・Slack共有: フォーマット・比較・identity_key/listing_key・load_json
├── optional_features.py   # オプショナル依存の一括ロード（asset_score/loan_calc/commute/price_predictor 等）
├── generate_report.py     # Markdownレポート生成（差分検出付き、report_utils・optional_features 利用）
├── slack_notify.py        # Slack通知（report_utils・optional_features 利用。generate_report には依存しない）
├── tests/                 # pytest
├── docs/                  # セットアップ・規約・実装メモ（下の「関連ドキュメント」参照）
└── scripts/               # 定期実行・キャッシュ取得・データ生成用
    ├── run_scrape.sh / run_enrich.sh / run_finalize.sh  # GitHub Actions が呼ぶ実行スクリプト
    ├── update_listings.sh  # ローカルで一括実行する用
    ├── build_map_viewer.py # 物件を地図上にマッピングした HTML を生成
    ├── geocode.py          # 住所→緯度経度（Nominatim、data/geocode_cache.json にキャッシュ）
    └── ...
```

Pythonモジュールは、役割ごとにファイルを分けてある（スクレイプ、予測、レポート、通知など）。

`report_utils.py` は、フォーマット、比較、差分検出用キー、重複除去用キー、`load_json` を提供する。差分検出用キーは `identity_key`（価格を除く同一判定）で、重複除去用キーは `listing_key`（価格を含む完全一致）である。

`optional_features.py` は、オプショナル依存を一箇所でロードする。対象はasset_score、loan_calc、commute、price_predictorなどである。未インストールのときは、"-" などの互換値を返す。`generate_report.py` と `slack_notify.py` は `optional_features` 経由で使う。そのため、optional依存に関する try/except ImportError を持たない。

差分検出では、名前、間取り、広さ、住所、築年、駅徒歩が同じ物件を同一物件とみなす（`identity_key`。価格は含まない）。価格だけが変わった物件はupdated（価格変動）に分類され、newとremovedにはならない。`main.py` のdedupには、`listing_key`（価格を含む）で完全一致した行を1件にまとめる段階がある。

## 使い方

### 準備

```bash
cd scraping-tool
pip install -r requirements.txt
```

### テスト（pytest）

差分検出、キー、フォーマットなどの仕様は、pytestで固定してある。lintとテストのコマンドは、[../.claude/CLAUDE.md](../.claude/CLAUDE.md) の Commands を参照してください。

### 実行例

いずれも `cd scraping-tool` したうえで実行する。Actionsと `update_listings.sh` は `python3` を使うため、`python3` を推奨する。

```bash
# SUUMO から1ページ取得し、条件フィルタをかけて JSON 出力
python3 main.py --max-pages 1 -o result.json

# フィルタなしで2ページ分の生データを取得
python3 main.py --max-pages 2 --no-filter -o raw.json

# 出力先を指定しない場合は標準出力に JSON
python3 main.py --max-pages 1

# HOME'S から取得
python3 main.py --source homes --max-pages 1 -o homes_result.json

# SUUMO と HOME'S の両方から取得
python3 main.py --source both --max-pages 1 -o all_result.json

# 全ソースから取得（DISABLED_SCRAPERS に入っているものはスキップ）
python3 main.py --source all -o all_result.json
```

`--max-pages` を省略すると、結果がなくなるまで全ページを取得する。

### main.py のオプション

| オプション | 説明 | デフォルト |
|------------|------|------------|
| `--source` | 取得元 `suumo` / `homes` / `athome` / `rehouse` / `nomucom` / `stepon` / `livable` / `all` / `both` | `suumo` |
| `--property-type` | 物件種別。`chuko`（中古）のみ | `chuko` |
| `--max-pages` | 最大ページ数。`0` は結果がなくなるまで全ページ取得 | 0 |
| `--no-filter` | 価格・専有・間取り・築年・徒歩の条件フィルタを行わない | オフ |
| `--output`, `-o` | 出力ファイル（`.csv` / `.json`）。未指定時は stdout に JSON | なし |

`both` はSUUMOとHOME'Sの2つ、`all` は全ソースを指す。

### 差分有無の判定（check_changes.py）

`update_listings.sh` で、変更があったときだけレポートと通知を出すために使う。同一物件は `identity_key`（価格を除く）で判定し、価格差分はupdatedとしてカウントする。

```bash
# 差分があれば exit 0、なければ exit 1
python3 check_changes.py current.json previous.json
```

### レポート生成

取得したJSONを、Markdown形式のレポートに変換する。検索条件（価格、専有、間取り、築年、徒歩）と、前回結果との差分（新規、価格変動、削除）も含む。

```bash
# 基本レポート生成
python3 generate_report.py result.json -o results/report/report.md

# 前回結果と比較して差分を表示
python3 generate_report.py result.json --compare previous.json -o results/report/report.md

# GitHub のレポートURLをレポート先頭に記載する（Actions 等で利用）
python3 generate_report.py result.json -o report.md --report-url "https://github.com/OWNER/REPO/blob/main/scraping-tool/results/report/report.md"
```

`results/report/` は `.gitignore` 対象で、リポジトリには含まれない。

generate_report.py のオプションは次のとおり。

| オプション | 説明 |
|------------|------|
| `input` | 入力JSON（main.py の出力） |
| `--compare`, `-c` | 前回結果JSON（差分検出用。省略時は差分セクションなし） |
| `--output`, `-o` | 出力Markdown（未指定時は stdout） |
| `--report-url` | レポート先頭に記載するGitHub URL（省略可） |
| `--map-url` | 物件マップ（HTML）のURL。スマホから開けるURLを指定する（省略可） |

レポートには次のセクションが含まれる。
- 検索条件: 価格、専有面積、間取り、築年、駅徒歩（config.py の設定）
- 変更サマリー: 新規、価格変動、削除の件数
- 新規物件: 前回にない物件（identity_key で判定）
- 価格変動: 同一物件で価格だけが変わったもの（identity_key で同一判定し、updatedとして表示）
- 削除された物件: 前回にあって今回ない物件
- 物件一覧: 区と最寄駅ごとに、資産性B以上の物件を表示する。10年後差額が大きい順に並べる

### 地図で物件を確認（map viewer）

取得した物件を地図上にマッピングして確認できる。住所はOpenStreetMap Nominatimでジオコーディングし、結果は `data/geocode_cache.json` に保存する。

```bash
# results/latest.json から地図用 HTML を生成（results/map_viewer.html）
python3 scripts/build_map_viewer.py

# 先頭 N 件だけ（テスト用。初回はジオコーディングで時間がかかります）
python3 scripts/build_map_viewer.py --limit 20
```

生成した `results/map_viewer.html` をブラウザで開くと、Leaflet地図上にマーカーが表示される。マーカーをクリックすると、物件名、価格、間取り、最寄駅、詳細リンクを確認できる。

`results/map_viewer.html` はリポジトリにコミットされる。GitHub Actionsの実行では、このHTMLを生成する。[htmlpreview.github.io](https://htmlpreview.github.io/) 経由のURLを、レポートのリンク（`--map-url`）に使う。スマホからも同じリンクで開ける。

### ローカルでの一括実行（update_listings.sh）

`scripts/update_listings.sh` は、スクレイピング、enrichment、レポート生成、通知、`results/` のGitコミットまでを、1回の実行で行う。

```bash
# 通常実行（Git操作も自動実行）
./scripts/update_listings.sh

# Git操作をスキップ（テスト時など）
./scripts/update_listings.sh --no-git
```

出力先は次のとおり。
- レポート: `scraping-tool/results/report/report.md`（毎回上書き）
- データ: `scraping-tool/results/current_YYYYMMDD_HHMMSS.json`（履歴用）

スクリプトの構成（Phase 1からPhase 3）と所要時間の集計は、スクリプト冒頭のコメントを参照してください。

### GitHub Actionsでの定期実行

本番の定期実行は、GitHub Actionsが行う。流れは次のとおり。
1. `.github/workflows/scrape-listings.yml` が `scripts/run_scrape.sh` を実行し、中古物件を取得する。実行時刻は [../README.md](../README.md) に書いてある。
2. `.github/workflows/enrich-and-report.yml` が、1の完了後に `run_enrich.sh` と `run_finalize.sh` を実行する。enrichment、レポート生成、Supabase同期（`scripts/sync_db.py`）を行い、結果をmainにgit pushする。
3. 手動で実行するときは、ActionsタブのRun workflowを使う。

セットアップの詳細は [docs/GITHUB_SETUP.md](./docs/GITHUB_SETUP.md) を参照してください。

### Slack通知

`slack_notify.py` は、変更があったときにSlackへ通知を送る。`optional_features` 経由で資産性と10年後予測などを利用し、`generate_report.py` には依存しない。

2026-07-07から、Slackへの送信は全経路で停止している。環境変数 `SLACK_NOTIFICATIONS_ENABLED=1` を設定したときだけ送信する。

```bash
# 使い方（SLACK_WEBHOOK_URL が未設定の場合は警告ののち exit 0 でスキップ）
python3 slack_notify.py current.json [previous.json] [report.md]
```

通知の内容は次のとおり。
- 現在の件数（資産性B以上のみカウント）
- 今回の変更（新規、削除、価格変動の件数）
- 新規追加された物件（最大10件）
- 価格変動した物件（最大5件、差額が大きい順）
- 削除された物件（最大5件）
- 物件一覧（区・駅別、資産性B以上）
- レポートへのリンク

セットアップは [docs/SLACK_SETUP.md](./docs/SLACK_SETUP.md) を参照してください。

## 条件フィルタ

条件の既定値は、`real-estate-ios/RealEstateApp/ScrapingConfigMetadata.json` の `defaults` が正である。`config.py` がこのファイルを読み込む。Supabaseの `scraping_config` テーブルが、実行時にこの値を上書きする。変更の手順は、[../.claude/CLAUDE.md](../.claude/CLAUDE.md) の「設定の単一ソース」に従ってください。

`ScrapingConfigMetadata.json` の `defaults` は、2026-10-02時点で次の値である。
- 価格: 7,500万円から11,500万円
- 専有面積: 60㎡以上（上限なし）
- 間取り: 先頭が2または3のもの
- 築年: 築30年以内（`builtYearMinOffsetYears`）
- 駅徒歩: 10分以内
- 総戸数: 20戸以上

本番で実際に使う値は、Supabaseの `scraping_config` で上書きされている可能性がある。

### 総戸数フィルタ

スクレイパーは、総戸数が分かった物件のうち `TOTAL_UNITS_MIN` 未満のものを除外する。総戸数が分からない物件は通過させて、取りこぼしを防ぐ。

SUUMOの一覧には総戸数が出ないため、詳細ページのキャッシュを使う。

1. 一度 `main.py` で取得した結果（`results/latest.json`）を用意する。
2. `python3 scripts/build_units_cache.py` を実行する。キャッシュにないURLは、詳細ページをHTTPで取得し、HTMLを `data/html_cache/` に保存する。パース結果（総戸数、所在階、階建、権利形態）は `data/building_units.json` に保存する。
3. 次回の実行では、キャッシュにHTMLがあるURLは再取得せず、ローカルのHTMLからパースする。所在階、階建、権利形態が一覧で取れない場合も、このキャッシュで補う。

### 駅乗降客数フィルタ（オプション）

国土数値情報の駅別乗降客数データ（S12）を1回取得すると、乗降客数が少ない駅の物件を除外できる。

1. [国土数値情報 S12](https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-S12-v3_1.html) から「S12-22_GML.zip」（令和3年・全国）をダウンロードし、`scraping-tool/data/` に置く。
2. `python scripts/fetch_station_passengers.py` を実行し、`data/station_passengers.json`（駅名から1日あたり乗降客数への対応）を生成する。
3. `config.py` で `STATION_PASSENGERS_MIN = 10000` などに設定すると、その値未満の駅の物件を除外する。`0` のときはフィルタをかけない（現在の既定は `0`）。

駅ごとの不動産価格の値上がり率は、オープンデータが少ないため、乗降客数を「需要の厚い駅」の代理指標にしている。

### 資産性ランク（参考表示）

レポートとSlackの物件行に、資産性ランク（S/A/B/C）を表示する。ランクは含み益率で決まり、10年後Standard予測とローン残債から算出する。しきい値は、10%以上でS、5%以上でA、0%以上でB、0%未満でCである（`asset_score.py`）。詳細は [docs/asset-ranking-feasibility.md](./docs/asset-ranking-feasibility.md) を参照してください。

### 通勤時間（通勤先2拠点）

レポートとSlackの物件行に、通勤先2拠点（オフィスAとオフィスB）までの通勤時間を表示する。実住所と名称は、環境変数 `COMMUTE_OFFICES_JSON` またはSupabaseが正である。リポジトリにはプレースホルダだけがある。

- `commute.py` は、`data/commute_m3career.json` と `data/commute_playground.json`（駅名から分数への対応）を読む。この2ファイルは `.gitignore` 対象で、リポジトリには含まれない。
- 駅名は、末尾の「駅」の有無にかかわらず照合する（「東新宿」と「東新宿駅」は同じ）。
- 未登録の駅は、徒歩分数と固定の目安分数から概算を表示する（`commute.py` 冒頭の説明）。
- 正確な所要時間は、Google Mapsを使う `commute_gmaps_enricher.py` などのenricherで取得する。

### 10年後成約価格予測（FutureEstatePredictor / MansionPricePredictor）

`price_predictor.py` は、内部で `future_estate_predictor.py` の `FutureEstatePredictor` を使う。現在の推定成約価格と、10年後の3シナリオ（Standardは中立、Bestは楽観、Worstは悲観）を算出する。

`FutureEstatePredictor` は、収益還元法（インカム）と原価法（コスト）の両方で10年後の価格を計算し、高い方を採用する。計算の詳細は [docs/calculation-summary.md](./docs/calculation-summary.md) と [docs/price-prediction-logic.md](./docs/price-prediction-logic.md) を参照してください。

外部データは次のとおり。
- `data/ward_potential.csv`: 区ごとの賃料成長ポテンシャル（S/A/B/C）と供給制約係数（future_estate_predictor 用）
- `data/ward_coefficients.csv`、`data/management_guidelines.csv`、`data/area_coefficients.csv` など: price_predictor の前処理と区判定用

入力は、`listing_price`（円）、`address`、`station_name` などか、`price_man`（万円）、`station_line` などのどちらでもよい。`listing_to_property_data()` で、既存のlisting辞書を変換できる。動作確認は `python3 price_predictor.py`（サンプル入力）で行う。

## 利用規約・注意

- 私的利用と軽負荷を前提とする。リクエスト間隔は、`config.py` の `*_REQUEST_DELAY_SEC` を下回らないようにする。2026-10-02時点の値は、SUUMO用の `REQUEST_DELAY_SEC` が2秒、HOME'Sとathomeが5秒である。rehouse、nomucom、stepon、livableは3秒である。
- 各サイトの利用規約は [docs/terms-check.md](./docs/terms-check.md) を参照し、利用前に最新の規約を確認してください。
- 出力は、候補を拾う一次フィルタ用である。管理書類での絞り込みと、REINSの成約確認は手動で行ってください。

## 関連ドキュメント

| ドキュメント | 内容 |
|--------------|------|
| [docs/calculation-summary.md](./docs/calculation-summary.md) | 10年後価格、騰落率、資産性ランクの計算方法（FutureEstatePredictor など） |
| [docs/price-prediction-logic.md](./docs/price-prediction-logic.md) | 価格予測ロジックの詳細 |
| [docs/GITHUB_SETUP.md](./docs/GITHUB_SETUP.md) | GitHub Actionsでの定期実行のセットアップ |
| [docs/SLACK_SETUP.md](./docs/SLACK_SETUP.md) | Slack通知のセットアップ |
| [docs/asset-ranking-feasibility.md](./docs/asset-ranking-feasibility.md) | 資産性ランクの可否と実現案 |
| [docs/feasibility-study.md](./docs/feasibility-study.md) | 実装可否の検討 |
| [docs/terms-check.md](./docs/terms-check.md) | 規約の確認結果 |
| [docs/refactor-evaluation-chatgpt.md](./docs/refactor-evaluation-chatgpt.md) | リファクタ指針の評価と実施状況 |
| [docs/HOMES_実装ガイド.md](./docs/HOMES_実装ガイド.md) | HOME'Sスクレイパーの実装ガイド |
| [docs/SUUMO_DETAIL_PARSER.md](./docs/SUUMO_DETAIL_PARSER.md) | SUUMO詳細ページのパーサ |
| [docs/CHANGELOG-slack-and-filter.md](./docs/CHANGELOG-slack-and-filter.md) | Slack通知とフィルタの変更履歴 |

購入条件（リポジトリルート）: [../docs/10year-index-mansion-conditions-draft.md](../docs/10year-index-mansion-conditions-draft.md)
