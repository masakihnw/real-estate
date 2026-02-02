# スクレイピングツール（REINS以外）

10年住み替え前提の中古マンション条件（[../docs/10year-index-mansion-conditions-draft.md](../docs/10year-index-mansion-conditions-draft.md)）を満たす物件を、**REINS以外**の物件サイト（SUUMO / HOME'S）から取得するツールです。

- **対象**: SUUMO（実装済）、HOME'S（実装済）
- **at home**: 規約でクローラー等による情報取得が明示禁止のため対象外
- **REINS**: 成約データは本ツールでは取得せず、手動でレインズマーケットインフォメーションを参照

## フォルダ構成

```
scraping-tool/
├── README.md              # 本ファイル
├── requirements.txt       # Python 依存
├── config.py              # 条件フィルタの閾値（価格・専有・間取り・築年・徒歩）
├── asset_score.py         # 資産性スコア・S/A/B/Cランク（含み益率ベース）
├── asset_simulation.py    # 10年シミュレーション（資産性試算用）
├── future_estate_predictor.py # 10年後価格予測（3シナリオ・収益還元・原価法ハイブリッド）
├── price_predictor.py    # 10年後成約価格予測（FutureEstatePredictor を利用、外部CSV利用）
├── loan_calc.py           # ローン月額試算（50年変動・諸経費込）
├── commute.py             # 通勤時間表示（エムスリーキャリア・playground、data/commute_*.json）
├── suumo_scraper.py       # SUUMO 中古マンション一覧スクレイパー
├── homes_scraper.py       # HOME'S スクレイパー（実装済）
├── main.py                # CLI エントリ（取得・重複除去）
├── check_changes.py       # 前回結果との差分有無判定（update_listings.sh で利用）
├── report_utils.py        # レポート・Slack共有: フォーマット・比較・identity_key/listing_key・load_json
├── optional_features.py   # オプショナル依存の一括ロード（asset_score/loan_calc/commute/price_predictor 等）
├── generate_report.py     # Markdownレポート生成（差分検出付き、report_utils・optional_features 利用）
├── slack_notify.py        # Slack通知（report_utils・optional_features 利用。generate_report には依存しない）
├── tests/                 # pytest（差分検出・キー・フォーマットのテスト）
├── docs/                  # セットアップ・規約・実装メモ
│   ├── GITHUB_SETUP.md
│   ├── SLACK_SETUP.md
│   ├── calculation-summary.md
│   ├── price-prediction-logic.md
│   ├── refactor-evaluation-chatgpt.md
│   ├── feasibility-study.md
│   ├── terms-check.md
│   └── HOMES_実装ガイド.md
└── scripts/               # 定期実行・キャッシュ取得用
```

**Python モジュールについて**: 役割ごとにファイルを分割しています（スクレイプ・予測・レポート・通知など）。一つのファイルにまとめず保守性を優先しています。`report_utils.py` はフォーマット・比較・**差分検出用キー**（`identity_key`：価格を除く同一判定）と**重複除去用キー**（`listing_key`：価格含む完全一致）および `load_json` を提供します。`optional_features.py` は asset_score / loan_calc / commute / price_predictor 等のオプショナル依存を一箇所でロードし、未インストール時は "-" 等の互換値を返します。`generate_report` と `slack_notify` は `optional_features` 経由で利用するため、両ファイルから try/except ImportError を撤去しています。`slack_notify` は `generate_report` に依存しません。

**差分検出の仕様**: 同一物件は **identity_key**（名前・間取り・広さ・住所・築年・駅徒歩。**価格は含まない**）で判定します。価格だけ変わった場合は **updated（価格変動）** として分類され、new/removed にはなりません。重複除去（main の dedupe）では **listing_key**（価格含む）を使い、完全一致した行のみ1件にまとめます。

## 使い方

### 準備

```bash
cd scraping-tool
pip install -r requirements.txt
```

### テスト（pytest）

差分検出・キー・フォーマットの仕様を固定するため、pytest でテストを実行できます。

```bash
cd scraping-tool
python3 -m pytest tests/ -v
```

### 実行例

いずれも `cd scraping-tool` したうえで実行します。`python3` を推奨（Actions / update_listings.sh では `python3` を使用）。

```bash
# SUUMO 関東・駅徒歩5分以内から1ページ取得し、条件フィルタをかけて JSON 出力
python3 main.py -o result.json

# フィルタなしで2ページ分の生データを取得
python3 main.py --max-pages 2 --no-filter -o raw.json

# 出力先を指定しない場合は標準出力に JSON
python3 main.py --max-pages 1

# HOME'S から取得
python3 main.py --source homes --max-pages 1 -o homes_result.json

# SUUMO と HOME'S の両方から取得
python3 main.py --source both --max-pages 1 -o all_result.json
```

### 差分有無の判定（check_changes.py）

`update_listings.sh` で「変更時のみレポート・通知」するために利用します。同一物件は **identity_key**（価格を除く）で判定し、価格差分は updated としてカウントします。

```bash
# 差分があれば exit 0、なければ exit 1
python3 check_changes.py current.json previous.json
```

### レポート生成（見やすい形式で出力）

取得したJSONをMarkdown形式の見やすいレポートに変換できます。**検索条件**（価格・専有・間取り・築年・徒歩）と、前回結果との**差分**（新規・価格変動・削除）も含みます。

**保存先**: 定期実行時は `scraping-tool/results/report/report.md` に保存されます。

```bash
# 基本レポート生成
python3 generate_report.py result.json -o results/report/report.md

# 前回結果と比較して差分を表示
python3 generate_report.py result.json --compare previous.json -o results/report/report.md

# GitHub のレポートURLをレポート先頭に記載する（Actions 等で利用）
python3 generate_report.py result.json -o report.md --report-url "https://github.com/OWNER/REPO/blob/main/scraping-tool/results/report/report.md"
```

**generate_report.py のオプション**:
| オプション | 説明 |
|------------|------|
| `input` | 入力JSON（main.py の出力） |
| `--compare`, `-c` | 前回結果JSON（差分検出用。省略時は差分セクションなし） |
| `--output`, `-o` | 出力Markdown（未指定時は stdout） |
| `--report-url` | レポート先頭に記載するGitHub URL（省略可） |

レポートには以下が含まれます：
- 🔍 **検索条件**: 価格・専有面積・間取り・築年・駅徒歩（config.py の設定）
- 📊 **変更サマリー**: 新規・価格変動・削除の件数
- 🆕 **新規物件**: 前回にない物件（identity_key で判定）
- 🔄 **価格変動**: 同一物件で価格だけ変わったもの（identity_key で同一判定し updated として表示）
- ❌ **削除された物件**: 前回はあったが今回ない物件
- 📋 **全物件一覧**: 区・最寄駅別、資産性B以上のみ。10年後差額が大きい順で表示

### 定期実行の例

定期的に情報を更新する場合のワークフロー例：

```bash
#!/bin/bash
# scripts/update_listings.sh

cd scraping-tool

# 1. データ取得
OUTPUT_DIR="results"
DATE=$(TZ=Asia/Tokyo date +%Y%m%d_%H%M%S)
CURRENT="${OUTPUT_DIR}/current_${DATE}.json"
PREVIOUS="${OUTPUT_DIR}/current_*.json"  # 最新の前回ファイル

python3 main.py --source both --max-pages 2 -o "$CURRENT"

# 2. 前回結果があれば差分レポート生成
LATEST_PREV=$(ls -t ${OUTPUT_DIR}/current_*.json 2>/dev/null | head -2 | tail -1)
if [ -n "$LATEST_PREV" ] && [ "$LATEST_PREV" != "$CURRENT" ]; then
    python3 generate_report.py "$CURRENT" --compare "$LATEST_PREV" \
        -o "${OUTPUT_DIR}/report_${DATE}.md"
    echo "差分レポート生成: ${OUTPUT_DIR}/report_${DATE}.md"
else
    python3 generate_report.py "$CURRENT" -o "${OUTPUT_DIR}/report_${DATE}.md"
    echo "レポート生成: ${OUTPUT_DIR}/report_${DATE}.md"
fi

# 3. 最新結果を latest.json として保存（次回比較用）
cp "$CURRENT" "${OUTPUT_DIR}/latest.json"
```

### GitHubへの自動コミット・プッシュ

`scripts/update_listings.sh` は実行後に自動的にGitコミット・プッシュを行います。

```bash
# 通常実行（Git操作も自動実行）
./scripts/update_listings.sh

# Git操作をスキップ（テスト時など）
./scripts/update_listings.sh --no-git
```

**動作**:
- `scraping-tool/results/` 内のファイルを自動的にステージング
- 変更サマリーを含むコミットメッセージでコミット
- リモートリポジトリに自動プッシュ

**出力先**:
- レポート: `scraping-tool/results/report/report.md`（毎回上書き）
- データ: `scraping-tool/results/current_YYYYMMDD_HHMMSS.json`（履歴用）

**コミットメッセージ例**:
```
Update listings: 20260128_132800

🆕 新規: 2件
🔄 価格変動: 1件
❌ 削除: 1件

取得件数: 3件
レポート: scraping-tool/results/report/report.md
```

### GitHub Actionsでの定期実行（推奨）

リポジトリに `.github/workflows/update-listings.yml` を配置すると、GitHub Actionsで自動実行できます。

**設定**:
1. リポジトリの `.github/workflows/update-listings.yml` が既に作成済み
2. デフォルトで毎日朝8時（JST）に自動実行
3. 手動実行も可能（Actions タブから "Run workflow"）

**メリット**:
- ローカル環境不要
- 自動でGitHubにコミット・プッシュ
- 実行履歴がGitHub上で確認可能

**詳細**: [docs/GITHUB_SETUP.md](./docs/GITHUB_SETUP.md) を参照

### Slack通知

ワークフロー実行後、変更があった場合にSlackに通知を送信します。`slack_notify.py` は `optional_features` 経由で資産性・10年後予測等を利用し、**generate_report には依存しません**。

```bash
# 使い方（SLACK_WEBHOOK_URL が未設定の場合は警告ののち exit 0 でスキップ）
python3 slack_notify.py current.json [previous.json] [report.md]
```

**通知内容**:
- 📊 現在の件数（資産性B以上のみカウント）
- ■ 今回の変更（新規・削除・価格変動の件数）
- 🆕 新規追加された物件（最大10件）
- 🔄 価格変動した物件（最大5件、差額が大きい順）
- ❌ 削除された物件（最大5件）
- 📋 物件一覧（区・駅別、資産性B以上）
- 📄 レポートへのリンク

**セットアップ**: [docs/SLACK_SETUP.md](./docs/SLACK_SETUP.md) を参照

**cron での定期実行（ローカル環境）**:
```bash
0 8 * * * cd /path/to/real-estate/scraping-tool && ./scripts/update_listings.sh
```

### オプション

| オプション | 説明 | デフォルト |
|------------|------|------------|
| `--source` | 取得元 `suumo` / `homes` / `both` | `suumo` |
| `--max-pages` | 最大ページ数（SUUMO: 関東駅徒歩5分以内の一覧） | 1 |
| `--no-filter` | 価格・専有・間取り・築年・徒歩の条件フィルタを行わない | オフ |
| `--output`, `-o` | 出力ファイル（`.csv` / `.json`）。未指定時は stdout に JSON | なし |

### 条件フィルタ（config.py）

- 価格: 7,500万〜1億円
- 専有面積: 55〜75㎡
- 間取り: 2LDK〜3LDK 系
- 築年: 1982年以降（新耐震目安）
- 駅徒歩: 10分以内（Must は5分以内だが、一覧では5分条件のURLを使用）

変更する場合は `config.py` の定数を編集してください。

### 総戸数100戸以上フィルタ

- **HOME'S**: 一覧の `textFeatureComment`（例: 総戸数143戸）から総戸数をパースし、100戸未満を除外。
- **SUUMO**: 一覧には総戸数が出ないため、**詳細ページのキャッシュ**を使用する。
  1. 一度 `main.py` で取得した結果（`results/latest.json`）を用意する。
  2. `python scripts/build_units_cache.py` を実行し、SUUMO 詳細ページから総戸数を取得して `data/building_units.json` に保存する。
  3. 次回以降のスクレイプで、キャッシュに載っている物件は総戸数100戸未満で除外される。キャッシュにない物件は通過（取りこぼし防止）。

### 駅乗降客数フィルタ（オプション）

- **国土数値情報**（駅別乗降客数データ S12）を1回取得し、乗降客数が少ない駅の物件を除外できる。
  1. [国土数値情報 S12](https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-S12-v3_1.html) から「S12-22_GML.zip」（令和3年・全国）をダウンロードし、`scraping-tool/data/` に置く。
  2. `python scripts/fetch_station_passengers.py` を実行し、`data/station_passengers.json`（駅名 → 1日あたり乗降客数）を生成する。
  3. `config.py` で `STATION_PASSENGERS_MIN = 10000` などに設定すると、その値未満の駅の物件が除外される。`0` のときはフィルタなし。
- 駅ごとの不動産価格値上がり率はオープンデータが少ないため、**乗降客数**を「需要の厚い駅」の代理指標として利用する。

### 資産性ランク（参考表示）

- レポート・Slackの物件行に **資産性ランク（S/A/B/C）** を表示する。独自スコア（駅乗降客数・徒歩・築年・総戸数）に基づく参考値。
- 詳細: [docs/asset-ranking-feasibility.md](./docs/asset-ranking-feasibility.md)

### 通勤時間（エムスリーキャリア・playground）

- レポート・Slackの物件行に **エムスリーキャリア**（虎ノ門）・**playground**（千代田区一番町）までの通勤時間を表示する。
- `data/commute_m3career.json` と `data/commute_playground.json` に「駅名 → 分数」の形式で登録する。東京23区・周辺の主要駅は乗換案内の目安で登録済み。
- 駅名は「東新宿」「東新宿駅」のどちらでも照合可能（末尾の「駅」を無視して照合）。未登録の駅は「-」。
- 正確な所要時間が必要な場合は、乗換案内API（例: ジョルダン乗換案内オープンAPI）で取得して JSON を更新するか、手動で編集して利用する。

### 10年後成約価格予測（FutureEstatePredictor / MansionPricePredictor）

- **price_predictor.py** は内部で **future_estate_predictor.py** の **FutureEstatePredictor** を利用し、「現在の推定成約価格」と「10年後の3シナリオ（Standard＝中立 / Best＝楽観 / Worst＝悲観）」を算出する。
- **FutureEstatePredictor** は 2026年1月時点の経済予測（日銀利上げ・賃料急騰・建築費高騰）に基づく3シナリオで、**収益還元法（インカム）**と**原価法（コスト）**の両方で10年後価格を計算し、**高い方**を採用。2026年市場補正（15分ずらし+5%、都心3区1.5億以上-5%、ZEH/リノベ+2%）を適用する。
- 外部データ:
  - **data/ward_potential.csv**: 区ごとの賃料成長ポテンシャル（S/A/B/C）と供給制約係数（future_estate_predictor 用）
  - **data/ward_coefficients.csv**, **data/management_guidelines.csv**, **data/area_coefficients.csv** 等: price_predictor の前処理・区判定用
- 入力は **listing_price(円)/address/station_name/...** または **price_man(万円)/station_line/...** の両対応。`listing_to_property_data()` で既存の listing 辞書を変換可能。
- 実行例: `python3 price_predictor.py`（サンプル入力で動作確認）。詳細は [docs/calculation-summary.md](./docs/calculation-summary.md) を参照。

## 利用規約・注意

- **私的利用・軽負荷**を前提としています。リクエスト間隔は `config.REQUEST_DELAY_SEC`（既定2秒）以上を推奨。
- 各サイトの利用規約は [docs/terms-check.md](./docs/terms-check.md) を参照し、利用前に必ず最新の規約を確認してください。
- 出力は「候補20件」を拾う一次フィルタ用です。管理書類での絞り込みや REINS 成約確認は手動で行ってください。

## 関連ドキュメント

| ドキュメント | 内容 |
|--------------|------|
| [docs/calculation-summary.md](./docs/calculation-summary.md) | 10年後価格・騰落率・資産性ランクの計算の仕方（FutureEstatePredictor 等） |
| [docs/price-prediction-logic.md](./docs/price-prediction-logic.md) | 価格予測ロジックの詳細 |
| [docs/GITHUB_SETUP.md](./docs/GITHUB_SETUP.md) | GitHub Actions での定期実行セットアップ |
| [docs/SLACK_SETUP.md](./docs/SLACK_SETUP.md) | Slack 通知のセットアップ |
| [docs/asset-ranking-feasibility.md](./docs/asset-ranking-feasibility.md) | 資産性ランクの可否・実現案 |
| [docs/feasibility-study.md](./docs/feasibility-study.md) | 実装可否検討 |
| [docs/terms-check.md](./docs/terms-check.md) | 規約確認結果 |
| [docs/refactor-evaluation-chatgpt.md](./docs/refactor-evaluation-chatgpt.md) | リファクタ指針の評価・実施状況メモ |
| [docs/HOMES_実装ガイド.md](./docs/HOMES_実装ガイド.md) | HOME'S スクレイパー実装ガイド |

- **購入条件（リポジトリルート）**: [../docs/10year-index-mansion-conditions-draft.md](../docs/10year-index-mansion-conditions-draft.md)
