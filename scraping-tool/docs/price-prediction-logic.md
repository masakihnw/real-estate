# 10年後成約価格予測の実装構成（MansionPricePredictor）

この文書は、`price_predictor.py` の入出力、処理の流れ、参照データの使われ方をまとめたものです。
`price_predictor.py` は、SUUMOとHOMESの掲載情報を入力に、現在の推定成約価格と10年後の3シナリオ価格を返します。
計算式と係数の正本は [calculation-summary.md](./calculation-summary.md) で、この文書には重ねて書きません。
記述は `price_predictor.py`、`future_estate_predictor.py`、`asset_score.py`、`evaluate.py` の現状の実装に合わせています。

---

## 1. 処理の流れ

`MansionPricePredictor.predict(property_data)` は次の順に処理します。

1. `preprocess()` が入力から特徴量を作ります。区名の判定、築年数、推定賃料の逆算を行います。
2. 売り出し価格が0以下か未入力の場合は、価格を0にした結果と `risk_factors` の「価格情報なし」を返して終わります。
3. `FutureEstatePredictor.predict()` を呼び、価格計算を委ねます。
   ここで行う計算は、収益還元法、原価法、2026年市場補正、含み益率です。式は calculation-summary.md を参照してください。
4. 戻り値を次のように読み替えます。

| 出力 | 元になる値 |
|------|------------|
| `current_estimated_contract_price` | `current_valuation`（売り出し価格×0.958） |
| `10y_forecast.standard` | 中立シナリオ（neutral）の価格 |
| `10y_forecast.best` | 楽観シナリオ（optimistic）の価格 |
| `10y_forecast.worst` | 悲観シナリオ（pessimistic）の価格 |
| `rent_yield_floor` | 悲観シナリオの価格。0の場合は None |
| `implied_gain_yen`、`implied_gain_ratio` | `FutureEstatePredictor` が計算した中立シナリオの含み益と含み益率 |
| `profit_level` | `investment_grade` がS/Aなら「高」、Bなら「中」、Cなら「低」 |

`risk_factors` と `positive_factors` の文言は、`investment_grade` で決まる固定の文です。
Cなら `risk_factors` に「金利・賃料悪化シナリオで残債割れリスク」を追加します。
S/Aなら `positive_factors` に「賃料・建築費シナリオで下値支持」を追加します。
`FutureEstatePredictor` の `strategic_advice` は、グレードに関係なく `positive_factors` への追加対象です。

資産性ランク（S/A/B/C）は `predict()` の戻り値に含みません。`asset_score.py` が `implied_gain_ratio` を `implied_gain_ratio_to_asset_rank` に渡し、ランクを決めます。閾値は calculation-summary.md の第2節にあります。

---

## 2. 入力データ構造

入力は次のどちらかの形式です。

### 形式A（円・駅名・㎡）

| キー | 説明 | 例 | 価格への反映 |
|------|------|-----|--------------|
| `listing_price` | 売り出し価格（円） | 85000000 | あり |
| `address` | 住所。区名の判定に使う。`ss_address`、`住所`、`addr` も同じ用途で読む | 東京都江東区豊洲3-2 | あり |
| `station_name` | 最寄駅名 | 豊洲 | なし |
| `walk_min` | 駅徒歩（分） | 5 | あり（15分ずらしボーナスの判定） |
| `area_sqm` | 専有面積（㎡） | 70.5 | なし |
| `build_year` | 竣工年 | 2018 | あり（原価法の減価） |
| `repair_reserve_fund` | 月額修繕積立金（円） | 12000 | なし |
| `management_fee` | 月額管理費（円） | 15000 | なし |
| `total_units` | 総戸数 | 400 | あり（原価法の減価） |
| `floor` | 所在階 | 20 | なし |
| `estimated_rent` | 推定月額賃料（円）。未入力なら逆算する | 任意 | あり（現行賃料） |
| `hazard_risk` | 災害リスクフラグ（0 なし、1 イエローゾーン、2 レッドゾーン） | 0 | なし |
| `notes`、`features`、`description`、`remarks`、`備考`、`特徴` | 備考や特徴の文章 | 任意 | あり（省エネ・リノベ判定） |

価格への反映が「なし」の項目は、`preprocess()` が特徴量として保持するだけで、`predict()` の価格計算には渡りません。

推定賃料が未入力で売り出し価格がある場合、`preprocess()` が `listing_price × キャップレート ÷ 12` で月額賃料を作ります。作った賃料は `current_rent` として、`FutureEstatePredictor` に渡す値です。
キャップレートは `ward_coefficients.csv` の `rent_cluster_group` で決めます。グループ1と2は3.5%（`CAP_RATE_TIER1`）、グループ3は4%（`CAP_RATE_TIER2`）、グループ4と5は4.5%（`CAP_RATE_TIER3`）です。住所から区名を判定できないときは、グループ5として4.5%を使います。

### 形式B（既存スクレイピング結果）

| キー | 説明 |
|------|------|
| `price_man` | 売り出し価格（万円） |
| `station_line` | 路線・駅表記（例 東京メトロ有楽町線「豊洲」徒歩5分） |
| `walk_min`、`area_m2`、`built_year`、`total_units`、`floor_position` など | 形式Aの項目に対応する |

`listing_to_property_data(listing)` が形式Bを形式Aに変換してから `predict()` に渡します。

---

## 3. 参照データ

`predict()` の価格の計算に使うデータは `data/ward_potential.csv` だけです。ほかのファイルは `preprocess()` が読み込むか、どのコードからも読み込まれません。

### 3.1 `data/ward_potential.csv`（価格計算に使用）

`FutureEstatePredictor` が読みます。区ごとの賃料成長ポテンシャルと供給制約係数を持ちます。係数の意味は calculation-summary.md の (A)(B) を参照してください。

| カラム | 説明 |
|--------|------|
| ward_name | 区名 |
| rent_growth_potential | 賃料成長ポテンシャル（S/A/B/C） |
| supply_constraint | 供給制約係数。原価法の価格にかける |

住所から区名を判定できない場合や、区がファイルにない場合は、ポテンシャルC、供給制約係数1.0を使います。ファイルが存在しない場合も同じです。

### 3.2 `data/ward_coefficients.csv`（前処理で使用、価格には未反映）

区単位の係数です。`preprocess()` が住所から区名を判定して該当行を読みます。

| カラム | 説明 |
|--------|------|
| ward_name | 区名 |
| rent_cluster_group | 賃料成長グループID（1〜5）。1と2をTier1、3をTier2、4と5をTier3に変換する |
| rent_cagr | 期待賃料年平均成長率 |
| inventory_trend_score | 在庫・需給スコア（1.0が基準） |
| tower_regulation_flag | タワーマンション規制・高さ制限（1 規制あり、0 なし） |

グループごとの `rent_cagr` は次のとおりです。

- グループ1（千代田、中央、港、渋谷）は0.055です。
- グループ2（新宿、目黒、品川、文京、台東）は0.050です。
- グループ3（江東、墨田、中野、世田谷、豊島）は0.045です。
- グループ4（杉並、大田、北、荒川）は0.038です。
- グループ5（板橋、練馬、江戸川、葛飾、足立）は0.040です。

`predict()` の価格計算で使うのは、このファイルから導いたキャップレート（第2節）だけです。`rent_cagr`、`inventory_trend_score`、`tower_regulation_flag` は特徴量に入りますが、`FutureEstatePredictor` には渡しません。住所から区名を判定できないときの既定値は、`rent_cluster_group` 5、`rent_cagr` 0.035、`inventory_trend_score` 1.0、`tower_regulation_flag` 0です。

### 3.3 `data/management_guidelines.csv`（前処理で使用、価格には未反映）

築年数帯ごとの適正修繕積立金（円/㎡）の目安です。`preprocess()` が築年数に合う行を探して `guideline_yen_per_sqm` を特徴量に入れますが、`predict()` の価格計算では使いません。

| カラム | 型 | 説明 |
|--------|-----|------|
| age_min | int64 | 築年数（年）の下限 |
| age_max | int64 | 築年数（年）の上限 |
| guideline_yen_per_sqm | float64 | 適正修繕積立金（円/㎡） |

```csv
age_min,age_max,guideline_yen_per_sqm
0,5,120
6,10,150
11,15,180
16,20,200
21,25,220
26,30,250
31,99,280
```

### 3.4 `data/macro_economic_scenarios.csv`（読み込みのみ、価格には未反映）

`load_data()` が読み込みますが、`predict()` はこの値を参照しません。実際の3シナリオは `future_estate_predictor.py` の `DEFAULT_MACRO_SCENARIOS` で定義しています。

| カラム | 型 | 説明 |
|--------|-----|------|
| scenario_id | str | standard / best / worst |
| scenario_name | str | 表示名 |
| price_multiplier | float64 | 価格にかける乗数 |
| description | str | 説明 |

```csv
scenario_id,scenario_name,price_multiplier,description
standard,Standard,1.0,現在のインフレ率と金利上昇が均衡するシナリオ
best,Inflation (Best),1.15,インフレ・建築費高騰が続き資産価格が上昇するシナリオ
worst,Stagnation (Worst),0.85,金利上昇により購買力が低下し需給が緩むシナリオ
```

### 3.5 `data/calibration.json`（未使用）

`MansionPricePredictor(calibration_path=...)` で指定でき、`_cal()` というメソッドで値を取り出す作りですが、現在はどこからも `_cal()` を呼んでいません。次の値を保存していますが、価格には影響しません。

| キー | 値 |
|------|-----|
| listing_to_contract_ratio | 0.958 |
| liquidity_penalty_120_150 / liquidity_penalty_150_300 | 0.98 / 0.95 |
| base_annual_depreciation / tier1_depreciation_mitigation | 0.012 / 0.5 |
| inventory_over_threshold / inventory_under_threshold | 1.1 / 0.95 |
| inventory_downside_factor / inventory_up_bonus | 0.5 / 0.02 |
| inventory_adjustment_clip_min / inventory_adjustment_clip_max | -0.10 / 0.05 |
| walk_threshold_min / walk_penalty_per_min / walk_penalty_tier3_mult | 7 / 0.01 / 1.5 |
| walk_adjustment_clip_min / walk_adjustment_clip_max | -0.15 / 0.0 |
| management_deficit_max_pct / management_per_sqm_weight | -0.15 / 0.0 |
| area_40_50_bonus_pct / zeh_renovation_bonus_pct | 0.03 / 0.015 |
| tower_large_bonus_pct / tower_trend_suppress | 0.03 / 0.98 |
| interest_sensitivity_tier1 / tier2 / tier3 | 1.0 / 0.98 / 0.92 |
| hazard_penalty_red / hazard_penalty_yellow | 0.90 / 0.97 |
| trend_coefficient_clip_min / trend_coefficient_clip_max | 0.90 / 1.10 |
| floor_bonus_per_floor / total_units_bonus_per_100 / mgmt_repair_per_sqm_bonus_per_100 | 0.0 / 0.0 / 0.0 |

### 3.6 `data/area_coefficients.csv`（価格予測では未使用）

駅単位の係数ファイルです。`price_predictor.py` を含む `scraping-tool` 直下のPythonコードは、このファイルを読み込みません。一方、`scripts/fetch_station_prices.py` と `scripts/station_price_trend_chart.py` は、このファイルを読み込みます。

---

## 4. `price_predictor.py` の定数

`price_predictor.py` の冒頭には、次の定数が定義されています。
`predict()` の価格計算から参照されるのは、次の定数だけです。

- 築年数の計算に使う `CURRENT_YEAR`
- 推定賃料の逆算に使う `CAP_RATE_TIER1`〜`CAP_RATE_TIER3`
- ランク判定に使う `IMPLIED_GAIN_RATIO_S`、`IMPLIED_GAIN_RATIO_A`、`IMPLIED_GAIN_RATIO_B`

残りは定義だけが残り、どこからも参照されません。
`FutureEstatePredictor` は、同名の `LISTING_TO_CONTRACT_RATIO` などを `future_estate_predictor.py` 側で別に持っています。

| 定数 | 値 | 説明 | 参照 |
|------|-----|------|------|
| CURRENT_YEAR | 2026 | 現在年（築年数算出用） | あり |
| CAP_RATE_TIER1 | 0.035 | 都心のキャップレート | あり |
| CAP_RATE_TIER2 | 0.04 | 準都心のキャップレート | あり |
| CAP_RATE_TIER3 | 0.045 | 郊外のキャップレート | あり |
| IMPLIED_GAIN_RATIO_S | 0.10 | 含み益率10%以上で資産性S | あり |
| IMPLIED_GAIN_RATIO_A | 0.05 | 5%以上でA | あり |
| IMPLIED_GAIN_RATIO_B | 0.0 | 0%以上でB、未満でC | あり |
| LISTING_TO_CONTRACT_RATIO | 0.958 | 売り出し→成約補正（東京カンテイ 2024下期乖離率 -4.19%） | なし |
| WALL_120M_YEN / WALL_150M_YEN / WALL_300M_YEN | 120_000_000 / 150_000_000 / 300_000_000 | 流動性ペナルティの価格帯の境界（円） | なし |
| LIQUIDITY_PENALTY_120_150 / LIQUIDITY_PENALTY_150_300 | 0.98 / 0.95 | 1.2億〜1.5億は-2%、1.5億〜3億は-5% | なし |
| INVENTORY_OVER_THRESHOLD / INVENTORY_UNDER_THRESHOLD | 1.1 / 0.95 | 在庫過多、品薄の閾値 | なし |
| INVENTORY_DOWNSIDE_FACTOR | 0.5 | 在庫過多時の減額係数 | なし |
| INVENTORY_UP_BONUS | 0.02 | 品薄時 +2% | なし |
| ZEH_RENOVATION_KEYWORDS | ["ZEH", "省エネ", "断熱", "リノベーション済", "リフォーム済"] | 省エネ・リノベ判定キーワード | なし |
| ZEH_RENOVATION_BONUS_PCT | 0.015 | 省エネ・リノベ +1.5% | なし |
| FOREIGN_REGULATION_TIER1_MIN_YEN | 100_000_000 | Best抑制の都心価格閾値（円） | なし |
| BEST_SCENARIO_TIER1_HIGH_SUPPRESS | 0.95 | Best抑制係数 | なし |
| BASE_ANNUAL_DEPRECIATION | 0.012 | 年間減価率 | なし |
| TIER1_DEPRECIATION_MITIGATION | 0.5 | Tier1の減価率緩和（50%） | なし |
| MANAGEMENT_DEFICIT_MAX_PCT | -0.15 | 修繕積立金不足時の最大補正 | なし |
| AREA_40_50_BONUS_PCT | 0.03 | 専有面積40以上50未満の補正（+3%） | なし |
| WALK_THRESHOLD_MIN | 7 | 徒歩減価が始まる閾値（分） | なし |
| DEFAULT_RENT_GROWTH | 1.05 | 賃料成長率の既定値 | なし |
| INTEREST_SENSITIVITY_TIER1 / TIER2 / TIER3 | 1.0 / 0.98 / 0.92 | 金利感応度 | なし |
| TOWER_LARGE_BONUS_PCT | 0.03 | タワーマンション適性エリアかつ大規模時 +3% | なし |
| TOWER_TREND_SUPPRESS | 0.98 | 高さ制限エリアで非大規模時のトレンド係数 | なし |
| TOWER_LARGE_UNITS_THRESHOLD / TOWER_LARGE_FLOOR_THRESHOLD | 200 / 20 | 大規模、タワー規模の判定（総戸数、階数） | なし |
| HAZARD_PENALTY_RED / HAZARD_PENALTY_YELLOW | 0.90 / 0.97 | 災害リスクペナルティ | なし |
| NEWBUILD_PARITY_AGE_MAX / NEWBUILD_PARITY_DEPRECIATION_MITIGATION | 10 / 0.2 | 築10年以内の経年減価20%緩和 | なし |
| TOWER_POTENTIAL_BONUS_PCT / TOWER_NO_POTENTIAL_PENALTY_PCT | 0.05 / -0.02 | 区別のタワー適性補正 | なし |

---

## 5. 出力形式

`python3 price_predictor.py` のサンプル入力（形式Aの例）で得た出力です。

```json
{
  "current_estimated_contract_price": 81430000,
  "10y_forecast": {
    "standard": 105151739,
    "best": 140795554,
    "worst": 81666667
  },
  "rent_yield_floor": 81666667,
  "implied_gain_yen": 36351863,
  "implied_gain_ratio": 0.4464,
  "profit_level": "高",
  "risk_factors": [],
  "positive_factors": [
    "賃料・建築費シナリオで下値支持",
    "2030年までの賃料急騰期に保有推奨。金利4%シナリオでも残債割れリスク低。"
  ]
}
```

| キー | 説明 |
|------|------|
| `current_estimated_contract_price` | 現在の推定成約価格（円）。売り出し価格×0.958 |
| `10y_forecast` | 10年後の予測価格（円）。standard、best、worstの3シナリオ |
| `rent_yield_floor` | 悲観シナリオの価格（円）。レポートとの互換のために残している項目で、収益還元による下値の計算は行っていない |
| `implied_gain_yen` | 中立シナリオの10年後価格から10年後ローン残高を引いた含み益（円） |
| `implied_gain_ratio` | 含み益を現在の推定成約価格で割った比率（小数4桁） |
| `profit_level` | 高、中、低のいずれか |
| `risk_factors` | 第1節で述べた固定文言のリスト。価格情報がない場合は「価格情報なし」 |
| `positive_factors` | 第1節で述べた固定文言と戦略アドバイスのリスト |

---

## 6. 実装ファイル・参照データ一覧

| 種別 | パス |
|------|------|
| 入口（入出力の整形） | `scraping-tool/price_predictor.py` |
| 価格計算 | `scraping-tool/future_estate_predictor.py` |
| ローン残高と区名抽出 | `scraping-tool/shared_utils.py` |
| 資産性ランク | `scraping-tool/asset_score.py` |
| バックテスト | `scraping-tool/evaluate.py` |
| 区別ポテンシャル（価格計算に使用） | `scraping-tool/data/ward_potential.csv` |
| 区別係数 | `scraping-tool/data/ward_coefficients.csv` |
| 管理目安 | `scraping-tool/data/management_guidelines.csv` |
| マクロシナリオ（未使用） | `scraping-tool/data/macro_economic_scenarios.csv` |
| 較正係数（未使用） | `scraping-tool/data/calibration.json` |
| 駅別係数（価格予測では未使用） | `scraping-tool/data/area_coefficients.csv` |

---

## 7. バックテスト（evaluate.py）

物件特徴と実績成約価格を読み、`predict()` が返す `current_estimated_contract_price` と実績成約価格の差からMAE、MAPE、Biasを算出します。`current_estimated_contract_price` は売り出し価格×0.958なので、評価の対象は売り出しから成約への補正係数です。10年後の予測価格は評価しません。

- 入力はCSVまたはJSONLです。
  `listing_price`、`address`、`station_name`、`walk_min`、`area_sqm`、`build_year` などの物件特徴が必要です。
  実績成約価格（`actual_contract_price`、`contract_price`、`成約価格`、`actual_price` のいずれか）も必要です。
- 出力はn（件数）、MAE（円）、MAPE（%）、Bias（円）です。Biasが正のときは、予測が実績より高めです。

```bash
python3 evaluate.py data/backtest_sample.csv
# --data-dir, --calibration でパス指定可。--use-listing-as-actual で実績カラム無し時は listing_price を実績として使用。
```

`--calibration` で渡す `calibration.json` は、第3.5節のとおり価格に影響しません。
