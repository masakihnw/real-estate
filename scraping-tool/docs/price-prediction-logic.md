# 10年後成約価格予測ロジック（MansionPricePredictor）

SUUMO/HOMES の掲載情報と外部係数データ（CSV）を組み合わせ、ルールベースで「現在の推定成約価格」と「10年後の3シナリオ価格」を算出するロジックの仕様です。**現状の実装と参照データをそのまま記載**しています。

---

## 1. 入力データ構造

予測の入力は以下のいずれかの形式を想定する。

### 形式A（円・駅名・㎡）

| キー | 説明 | 例 |
|------|------|-----|
| `listing_price` | 売り出し価格（円） | 85000000 |
| `address` | 住所（区名判定用。未入力時は係数デフォルト） | 東京都江東区豊洲3-2 |
| `station_name` | 最寄駅名 | 豊洲 |
| `walk_min` | 駅徒歩（分） | 5 |
| `area_sqm` | 専有面積（㎡） | 70.5 |
| `build_year` | 竣工年（築年数算出用） | 2018 |
| `repair_reserve_fund` | 月額修繕積立金（円） | 12000 |
| `management_fee` | 月額管理費（円） | 15000 |
| `total_units` | 総戸数 | 400 |
| `floor` | 所在階 | 20 |
| `estimated_rent` | 推定月額賃料（円）。未入力時は `listing_price` とエリア利回りで逆算 | 任意 |
| `hazard_risk` | 災害リスクフラグ（0:なし, 1:イエローゾーン, 2:レッドゾーン） | 0 |
| `notes` / `features` / `description` / `remarks` / `備考` / `特徴` | 備考・特徴テキスト（省エネ・リノベ判定用） | 任意 |

- **推定賃料の逆算**: `estimated_rent` が無い場合は、`listing_price × キャップレート ÷ 12` で月額賃料を算出。キャップレートは Tier1=3.5%、Tier2=4%、Tier3=4.5%（都心3.5%、郊外4.5%等）。

### 形式B（既存スクレイピング結果）

| キー | 説明 |
|------|------|
| `price_man` | 売り出し価格（万円） |
| `station_line` | 路線・駅表記（例: 東京メトロ有楽町線「豊洲」徒歩5分） |
| `walk_min`, `area_m2`, `built_year`, `total_units`, `floor_position` 等 | 上記と対応 |

`listing_to_property_data(listing)` で形式B→形式A相当に変換してから `predict()` に渡す。

---

## 2. 参照データ（外部CSV）

予測で参照するデータはすべて `data/` 配下のCSVを pandas で読み込む。

### 2.1 `data/ward_coefficients.csv`（区単位係数・5賃料成長グループ）

**行政区（Ward）単位**の係数。入力の `address` から区名を判定し、該当行を参照。**5つの賃料成長グループ**と**在庫・需給スコア**、**高さ制限フラグ**で定義。

**カラム:**

| カラム | 型 | 説明 |
|--------|-----|------|
| ward_name | str | 区名 |
| rent_cluster_group | int | 賃料成長グループID（1〜5）。1,2→Tier1, 3→Tier2, 4,5→Tier3 に変換して経年減価・金利感応度に使用 |
| rent_cagr | float | 期待賃料年平均成長率（CAGR）。Yield Floor で 10年後賃料 = 現在賃料 × (1+rent_cagr)^10 |
| inventory_trend_score | float | 在庫・需給スコア（1.0基準）。都心3区 0.95／城東・城南 1.03／その他 1.0。1.5億の壁と組み合わせて流動性ペナルティに使用 |
| tower_regulation_flag | int | タワマン規制・高さ制限（1: 規制あり・経年減価1.1倍／0: 大規模開発可・200戸以上で+3%） |

**賃料成長グループ例:**

- Group1（千代田/中央/港/渋谷）: rent_cagr 0.055
- Group2（新宿/目黒/品川/文京/台東）: 0.050
- Group3（江東/墨田/中野/世田谷/豊島）: 0.045
- Group4（杉並/大田/北/荒川）: 0.038
- Group5（板橋/練馬/江戸川/葛飾/足立）: 0.040

- 住所から区名を正規表現で抽出。`address` 未入力時は rent_cluster_group=5, rent_cagr=0.035, inventory_trend_score=1.0, tower_regulation_flag=0 で補完。

---

### 2.2 `data/calibration.json`

徒歩・減価率・在庫・管理不足などの係数を外出しし、評価→更新可能にする。`MansionPricePredictor(calibration_path=...)` で指定可能。存在しないキーはコード内のデフォルトを使用。

**主なキー（抜粋）:**

| キー | 説明 | 例 |
|------|------|-----|
| listing_to_contract_ratio | 売り出し→成約補正 | 0.958 |
| base_annual_depreciation | 年間減価率 | 0.012 |
| inventory_over_threshold / inventory_under_threshold | 在庫過多/品薄の閾値 | 1.1 / 0.95 |
| inventory_adjustment_clip_min / inventory_adjustment_clip_max | 在庫調整の上下限（暴走クリップ） | -0.10 / 0.05 |
| walk_threshold_min / walk_penalty_per_min | 徒歩減価の閾値・1分あたり係数 | 7 / 0.01 |
| walk_adjustment_clip_min / walk_adjustment_clip_max | 徒歩調整の上下限（暴走クリップ） | -0.15 / 0.0 |
| management_deficit_max_pct | 修繕不足の最大補正 | -0.15 |
| trend_coefficient_clip_min / trend_coefficient_clip_max | トレンド係数のクリップ | 0.90 / 1.10 |
| floor_bonus_per_floor / total_units_bonus_per_100 / mgmt_repair_per_sqm_bonus_per_100 | 階・総戸数・（管理+修繕）/㎡ の較正対象 | 0.0 |

- **シナリオ整合性**: worst ≤ standard ≤ best を強制。Yield floor は `worst = min(max(worst, rent_yield_floor), standard)` で適用。

---

### 2.3 `data/management_guidelines.csv`

築年数帯ごとの適正修繕積立金（円/㎡）目安。管理品質補正で使用。

**カラム:**

| カラム | 型 | 説明 |
|--------|-----|------|
| age_min | int64 | 築年数（年）の下限 |
| age_max | int64 | 築年数（年）の上限 |
| guideline_yen_per_sqm | float64 | 適正修繕積立金（円/㎡） |

**実データ（全文）:**

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

---

### 2.4 `data/macro_economic_scenarios.csv`

シナリオID・名称・価格乗数。10年後3シナリオの算出に使用。

**カラム:**

| カラム | 型 | 説明 |
|--------|-----|------|
| scenario_id | str | standard / best / worst |
| scenario_name | str | 表示名 |
| price_multiplier | float64 | adjusted_10y に乗じる係数 |
| description | str | 説明（予測計算では未使用） |

**実データ（全文）:**

```csv
scenario_id,scenario_name,price_multiplier,description
standard,Standard,1.0,現在のインフレ率と金利上昇が均衡するシナリオ
best,Inflation (Best),1.15,インフレ・建築費高騰が続き資産価格が上昇するシナリオ
worst,Stagnation (Worst),0.85,金利上昇により購買力が低下し需給が緩むシナリオ
```

---

## 3. 定数一覧（実装と同一）

`price_predictor.py` で定義されている定数。

| 定数 | 値 | 説明 |
|------|-----|------|
| LISTING_TO_CONTRACT_RATIO | 0.958 | 売り出し→成約補正係数（東京カンテイ 2024下期乖離率 -4.19%） |
| WALL_120M_YEN | 120_000_000 | 流動性ペナルティ開始（円） |
| WALL_150M_YEN | 150_000_000 | 高額帯ペナルティ開始（円） |
| WALL_300M_YEN | 300_000_000 | 3億円以上はペナルティなし（円） |
| LIQUIDITY_PENALTY_120_150 | 0.98 | 1.2億〜1.5億: -2% |
| LIQUIDITY_PENALTY_150_300 | 0.95 | 1.5億〜3億: -5% |
| INVENTORY_OVER_THRESHOLD | 1.1 | 在庫過多の閾値 |
| INVENTORY_UNDER_THRESHOLD | 0.95 | 品薄の閾値 |
| INVENTORY_DOWNSIDE_FACTOR | 0.5 | 在庫過多時の減額係数（粘着性考慮で半分） |
| INVENTORY_UP_BONUS | 0.02 | 品薄時 +2% |
| ZEH_RENOVATION_KEYWORDS | ["ZEH", "省エネ", "断熱", "リノベーション済", "リフォーム済"] | 省エネ・リノベ判定キーワード |
| ZEH_RENOVATION_BONUS_PCT | 0.015 | 省エネ・リノベ +1.5% |
| FOREIGN_REGULATION_TIER1_MIN_YEN | 100_000_000 | Best抑制の都心価格閾値（円） |
| BEST_SCENARIO_TIER1_HIGH_SUPPRESS | 0.95 | Bestシナリオ都心1億以上の抑制係数 |
| BASE_ANNUAL_DEPRECIATION | 0.012 | ベースライン年間減価率（1.2%） |
| TIER1_DEPRECIATION_MITIGATION | 0.5 | Tier1の減価率緩和（50%） |
| MANAGEMENT_DEFICIT_MAX_PCT | -0.15 | 修繕積立金不足時の最大補正（-15%） |
| AREA_40_50_BONUS_PCT | 0.03 | 40以上50未満のプラス補正（+3%。2026年改正で中古40㎡以上が減税対象） |
| WALK_THRESHOLD_MIN | 7 | 徒歩減価が始まる閾値（分） |
| CURRENT_YEAR | 2026 | 現在年（築年数算出用） |
| CAP_RATE_TIER1 | 0.035 | 都心 キャップレート 3.5%（賃料逆算・Yield Floor用） |
| CAP_RATE_TIER2 | 0.04 | 準都心 4% |
| CAP_RATE_TIER3 | 0.045 | 郊外 4.5% |
| DEFAULT_RENT_GROWTH | 1.05 | 賃料成長率のデフォルト（CSV未定義時） |
| INTEREST_SENSITIVITY_TIER1 | 1.0 | 金利感応度 都心: 影響なし |
| INTEREST_SENSITIVITY_TIER2 | 0.98 | 準都心: -2% |
| INTEREST_SENSITIVITY_TIER3 | 0.92 | 郊外: -8%（2025年12月利上げ・頭打ちを反映） |
| HAZARD_PENALTY_RED | 0.90 | hazard_risk==2: -10% |
| HAZARD_PENALTY_YELLOW | 0.97 | hazard_risk==1: -3% |
| TOWER_LARGE_BONUS_PCT | 0.03 | タワマン適性エリアかつ大規模時 +3% |
| TOWER_TREND_SUPPRESS | 0.98 | 高さ制限エリアで非大規模時のトレンド係数 |
| TOWER_LARGE_UNITS_THRESHOLD | 200 | 総戸数これ以上で「大規模」 |
| TOWER_LARGE_FLOOR_THRESHOLD | 20 | 階数これ以上で「タワマン規模」 |

---

## 4. 実装コード（price_predictor.py と一致）

### 4.1 モジュール先頭・定数・ヘルパー

```python
from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Optional

import pandas as pd

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"

# ステップ1: 売り出し→成約補正（東京カンテイ 2024下期乖離率 -4.19%）
LISTING_TO_CONTRACT_RATIO = 0.958
# 価格帯別流動性ペナルティ（1.2億〜1.5億: -2%, 1.5億〜3億: -5%, 3億以上: なし）
WALL_120M_YEN = 120_000_000
WALL_150M_YEN = 150_000_000
WALL_300M_YEN = 300_000_000
LIQUIDITY_PENALTY_120_150 = 0.98   # 1.2億〜1.5億: -2%
LIQUIDITY_PENALTY_150_300 = 0.95   # 1.5億〜3億: -5%
# 在庫・需給バランス
INVENTORY_OVER_THRESHOLD = 1.1     # 在庫過多
INVENTORY_UNDER_THRESHOLD = 0.95   # 品薄
INVENTORY_DOWNSIDE_FACTOR = 0.5    # 在庫過多時の減額係数（粘着性考慮で半分）
INVENTORY_UP_BONUS = 0.02          # 品薄時 +2%
# 省エネ・リノベ付加価値
ZEH_RENOVATION_KEYWORDS = ["ZEH", "省エネ", "断熱", "リノベーション済", "リフォーム済"]
ZEH_RENOVATION_BONUS_PCT = 0.015   # +1.5%
# Bestシナリオ抑制（都心1億円以上・外国人規制考慮）
FOREIGN_REGULATION_TIER1_MIN_YEN = 100_000_000
BEST_SCENARIO_TIER1_HIGH_SUPPRESS = 0.95

# ステップ2: ベースライン経年減価（年間減価率）
BASE_ANNUAL_DEPRECIATION = 0.012  # 1.2%
TIER1_DEPRECIATION_MITIGATION = 0.5  # Tier1は50%緩和 → 0.6%

# ステップ3: 個別要因
MANAGEMENT_DEFICIT_MAX_PCT = -0.15  # 修繕積立金不足 最大-15%
AREA_40_50_BONUS_PCT = 0.03  # 40以上50未満 +3%
WALK_THRESHOLD_MIN = 7  # 徒歩7分以内は減価なし
CURRENT_YEAR = 2026

# 賃料・利回り（推定賃料逆算・Yield Floor用）。賃料成長率はCSVの rent_growth_rate を使用
CAP_RATE_TIER1 = 0.035   # 都心 3.5%
CAP_RATE_TIER2 = 0.04    # 準都心 4%
CAP_RATE_TIER3 = 0.045   # 郊外 4.5%
DEFAULT_RENT_GROWTH = 1.05  # CSV未定義時
# 金利上昇感応度（Standard/Worstに適用）。Tier3は2025年12月利上げを反映
INTEREST_SENSITIVITY_TIER1 = 1.0
INTEREST_SENSITIVITY_TIER2 = 0.98
INTEREST_SENSITIVITY_TIER3 = 0.92
# 災害リスクペナルティ
HAZARD_PENALTY_RED = 0.90
HAZARD_PENALTY_YELLOW = 0.97
# タワマン・大規模ボーナス／高さ制限エリアのトレンド抑制
TOWER_LARGE_BONUS_PCT = 0.03
TOWER_TREND_SUPPRESS = 0.98
TOWER_LARGE_UNITS_THRESHOLD = 200
TOWER_LARGE_FLOOR_THRESHOLD = 20


def _station_name_from_listing(station_raw: Optional[str], station_line: Optional[str]) -> Optional[str]:
    """listing の station_name または station_line から駅名を1つ取得。"""
    if station_raw and str(station_raw).strip():
        return str(station_raw).strip()
    if not station_line or not str(station_line).strip():
        return None
    m = re.search(r"[「『]([^」』]+)[」』]", str(station_line))
    if m:
        return m.group(1).strip()
    m = re.search(r"([^\s/]+駅)", str(station_line))
    if m:
        return m.group(1).strip()
    return (str(station_line).strip()[:30] or "").strip() or None


def _listing_price_yen(property_data: dict[str, Any]) -> Optional[float]:
    """円建ての売り出し価格を返す。price_man のみの場合は万円→円に変換。"""
    listing = property_data.get("listing_price")
    if listing is not None and listing != "":
        return float(listing)
    man = property_data.get("price_man")
    if man is not None and man != "":
        return float(man) * 10000
    return None
```

---

### 4.2 load_data（外部CSV読み込み）

```python
def load_data(self) -> None:
    """外部CSVを読み込み、予測に使うデータを保持する。"""
    self._area_coefficients = pd.read_csv(
        self.data_dir / "area_coefficients.csv",
        encoding="utf-8",
        dtype={"station_name": str, "area_rank": str, "trend_coefficient": "float64"},
    )
    if "inventory_pressure" not in self._area_coefficients.columns:
        self._area_coefficients["inventory_pressure"] = 1.0
    else:
        self._area_coefficients["inventory_pressure"] = pd.to_numeric(
            self._area_coefficients["inventory_pressure"], errors="coerce"
        ).fillna(1.0)
    if "rent_growth_rate" not in self._area_coefficients.columns:
        self._area_coefficients["rent_growth_rate"] = DEFAULT_RENT_GROWTH
    else:
        self._area_coefficients["rent_growth_rate"] = pd.to_numeric(
            self._area_coefficients["rent_growth_rate"], errors="coerce"
        ).fillna(DEFAULT_RENT_GROWTH)
    if "tower_eligible" not in self._area_coefficients.columns:
        self._area_coefficients["tower_eligible"] = 0
    else:
        self._area_coefficients["tower_eligible"] = pd.to_numeric(
            self._area_coefficients["tower_eligible"], errors="coerce"
        ).fillna(0).astype(int)
    self._management_guidelines = pd.read_csv(
        self.data_dir / "management_guidelines.csv",
        encoding="utf-8",
        dtype={"age_min": "int64", "age_max": "int64", "guideline_yen_per_sqm": "float64"},
    )
    self._macro_scenarios = pd.read_csv(
        self.data_dir / "macro_economic_scenarios.csv",
        encoding="utf-8",
        dtype={"scenario_id": str, "scenario_name": str, "price_multiplier": "float64"},
    )
    self._loaded = True
```

- `area_coefficients.csv` に `inventory_pressure` が無い場合は列ごと 1.0、ある場合は数値化し欠損を 1.0 で補完。

---

### 4.3 preprocess（特徴量生成）

```python
def preprocess(self, property_data: dict[str, Any]) -> dict[str, Any]:
    """特徴量を生成する。入力は listing_price(円)/station_name/... または price_man(万円)/station_line/... の両対応。"""
    self._ensure_loaded()
    listing_price = _listing_price_yen(property_data)
    station_name = _station_name_from_listing(
        property_data.get("station_name"),
        property_data.get("station_line"),
    )
    # walk_min, area_sqm, build_year, repair_reserve_fund, management_fee, total_units, floor を取得（省略）
    # age_years = max(0, CURRENT_YEAR - build_year)
    # repair_yen_per_sqm = repair_reserve_fund / area_sqm （area_sqm>0 かつ repair_reserve_fund がある場合）

    # エリアランク・トレンド係数・在庫・賃料成長率・タワマン適性（駅名は「駅」有無・前後空白を正規化して照合）
    area_rank = "Tier3"
    trend_coefficient = 1.0
    inventory_pressure = 1.0
    rent_growth_rate = DEFAULT_RENT_GROWTH
    tower_eligible = 0
    if station_name and self._area_coefficients is not None:
        station_name_clean = (str(station_name).strip().rstrip("駅").strip() or "")
        df = self._area_coefficients
        s = df["station_name"].astype(str).str.strip().str.rstrip("駅").str.strip()
        match = df[s == station_name_clean]
        if not match.empty:
            row = match.iloc[0]
            area_rank = str(row["area_rank"])
            trend_coefficient = float(row["trend_coefficient"])
            inventory_pressure = float(row.get("inventory_pressure", 1.0))
            rent_growth_rate = float(row.get("rent_growth_rate", DEFAULT_RENT_GROWTH))
            tower_eligible = int(row.get("tower_eligible", 0))

    # 築年数に応じた適正修繕積立金/㎡（management_guidelines の age_min <= age_years <= age_max で guideline_yen_per_sqm を取得）

    return {
        "listing_price": listing_price,
        "station_name": station_name,
        "area_rank": area_rank,
        "trend_coefficient": trend_coefficient,
        "inventory_pressure": inventory_pressure,
        "rent_growth_rate": rent_growth_rate,
        "tower_eligible": tower_eligible,
        "walk_min": walk_min,
        "area_sqm": area_sqm,
        "build_year": build_year,
        "age_years": age_years,
        "repair_reserve_fund": repair_reserve_fund,
        "repair_yen_per_sqm": repair_yen_per_sqm,
        "guideline_yen_per_sqm": guideline_yen_per_sqm,
        "management_fee": management_fee,
        "total_units": total_units,
        "floor": floor,
        "estimated_rent": estimated_rent,
        "hazard_risk": hazard_risk,
    }
```

- 駅名は `station_name` を strip / 末尾「駅」除去して `area_coefficients` の `station_name` と照合。一致した行から `area_rank`, `trend_coefficient`, `inventory_pressure`, `rent_growth_rate`, `tower_eligible` を取得。未一致は area_rank=Tier3, trend_coefficient=1.0, inventory_pressure=1.0, rent_growth_rate=DEFAULT_RENT_GROWTH, tower_eligible=0。
- 築年数は `CURRENT_YEAR - build_year`。`management_guidelines` の `age_min <= age_years <= age_max` を満たす行の `guideline_yen_per_sqm` を採用。

---

### 4.4 predict（ステップ1: 実勢価格＋流動性ペナルティ）

```python
# ステップ1: 実勢価格への補正（Listing to Contract）＋価格帯別流動性ペナルティ
contract_price = listing_price * LISTING_TO_CONTRACT_RATIO
if contract_price >= WALL_150M_YEN and contract_price < WALL_300M_YEN:
    contract_price *= LIQUIDITY_PENALTY_150_300
    risk_factors.append("高額帯・流動性低下懸念")
elif contract_price >= WALL_120M_YEN and contract_price < WALL_150M_YEN:
    contract_price *= LIQUIDITY_PENALTY_120_150
    risk_factors.append("1.2億円の壁対象")
# 3.0億円以上はペナルティなし（超富裕層向け別市場）
```

- **(B) 1.5億の壁と在庫リスク**: 1.5億〜3億かつ `inventory_trend_score` < 1.0（都心3区）のとき流動性ペナルティ **-8%**、リスク「在庫調整局面(都心3区・高額帯)」。1.5〜3億で在庫≥1.0のときは従来どおり ×0.95「高額帯・流動性低下懸念」。1.2億以下はペナルティなし。
- 1.2億〜1.5億: ×0.98、リスク「1.2億円の壁対象」。
- 3億以上: 変更なし。

---

### 4.5 predict（ステップ2: ベースライン経年減価）

```python
# ステップ2: ベースライン経年減価
area_rank = features.get("area_rank") or "Tier3"
if area_rank == "Tier1":
    annual_dep = BASE_ANNUAL_DEPRECIATION * (1.0 - TIER1_DEPRECIATION_MITIGATION)
else:
    annual_dep = BASE_ANNUAL_DEPRECIATION
total_dep = min(annual_dep * 10, 0.99)
base_10y = contract_price * (1.0 - total_dep)
```

- Tier1: 年間 0.6%、10年で最大 6% 減価。
- それ以外: 年間 1.2%、10年で最大 12% 減価（上限 99%）。

---

### 4.6 predict（ステップ2.5: 在庫・需給バランス）

```python
# ステップ2.5: 在庫・需給バランスによる価格調整
inventory_pressure = float(features.get("inventory_pressure", 1.0))
if inventory_pressure > INVENTORY_OVER_THRESHOLD:
    downside = (inventory_pressure - 1.0) * INVENTORY_DOWNSIDE_FACTOR
    base_10y *= 1.0 - downside
    risk_factors.append("在庫過多エリア（価格調整リスクあり）")
elif inventory_pressure < INVENTORY_UNDER_THRESHOLD:
    base_10y *= 1.0 + INVENTORY_UP_BONUS
    positive_factors.append("新築供給減による希少性")
```

- `inventory_pressure` > 1.1: 減額率 = (inventory_pressure - 1.0) × 0.5。リスク「在庫過多エリア（価格調整リスクあり）」追加。
- `inventory_pressure` < 0.95: base_10y × 1.02。ポジティブ要因「新築供給減による希少性」追加。

---

### 4.7 predict（ステップ3: 個別要因スコアリング）

```python
# ステップ3: 個別要因スコアリング（係数 1.0 を基準に加算）
quality_adj = 0.0

# 3a. 管理品質補正（修繕積立金不足で最大-15%）
guideline = features.get("guideline_yen_per_sqm")
repair_per_sqm = features.get("repair_yen_per_sqm")
if guideline is not None and guideline > 0 and repair_per_sqm is not None:
    if repair_per_sqm < guideline:
        shortfall_ratio = 1.0 - (repair_per_sqm / guideline)
        quality_adj += shortfall_ratio * MANAGEMENT_DEFICIT_MAX_PCT
        risk_factors.append("修繕積立金不足")

# 3b. 専有面積トレンド補正（40以上50未満で+3%。2026年改正で中古40㎡以上が減税対象）
area_sqm = features.get("area_sqm")
if area_sqm is not None and 40 <= area_sqm < 50:
    quality_adj += AREA_40_50_BONUS_PCT

# 3c. 省エネ・リノベ付加価値（ZEH/断熱/リノベ等キーワードで+1.5%）
text_parts = []
for key in ("notes", "features", "description", "remarks", "備考", "特徴"):
    val = property_data.get(key)
    if val is not None and isinstance(val, str):
        text_parts.append(val)
combined_text = " ".join(text_parts)
if any(kw in combined_text for kw in ZEH_RENOVATION_KEYWORDS):
    quality_adj += ZEH_RENOVATION_BONUS_PCT

# 3d. 駅距離の非線形評価（7分以内=0、8分以降は加速度的に減価、郊外で特に厳しく）
walk_min = features.get("walk_min")
if walk_min is not None and walk_min > WALK_THRESHOLD_MIN:
    excess = walk_min - WALK_THRESHOLD_MIN
    walk_penalty = -0.01 * excess * (1.0 + excess * 0.1)
    if area_rank == "Tier3":
        walk_penalty *= 1.5
    quality_adj += walk_penalty

quality_score = 1.0 + quality_adj
adjusted_10y = base_10y * quality_score

# ステップ3.5: タワマン・大規模ボーナス／高さ制限エリアのトレンド抑制
total_units = features.get("total_units") or 0
floor = features.get("floor") or 0
tower_eligible = int(features.get("tower_eligible", 0) or 0)
is_tower_large = (total_units >= TOWER_LARGE_UNITS_THRESHOLD) or (floor >= TOWER_LARGE_FLOOR_THRESHOLD)
if is_tower_large and tower_eligible == 1:
    adjusted_10y *= 1.0 + TOWER_LARGE_BONUS_PCT
    positive_factors.append("大規模タワープレミアム")
elif tower_eligible == 0 and not is_tower_large:
    adjusted_10y *= TOWER_TREND_SUPPRESS

# 賃料上昇期待エリア（rent_growth_rate >= 1.08 で positive_factors に追加）
rent_growth_rate = float(features.get("rent_growth_rate", DEFAULT_RENT_GROWTH) or DEFAULT_RENT_GROWTH)
if rent_growth_rate >= 1.08:
    positive_factors.append("賃料上昇期待エリア")
```

- 3a: 修繕円/㎡ < 基準円/㎡ のとき、不足率に応じて最大 -15%、リスク「修繕積立金不足」。
- 3b: 40≤area_sqm<50 のとき +3%。
- 3c: `notes`/`features`/`description`/`remarks`/`備考`/`特徴` を結合し、ZEH_RENOVATION_KEYWORDS のいずれかが含まれれば +1.5%。
- 3d: 徒歩 > 7分のとき excess = walk_min - 7、walk_penalty = -0.01 * excess * (1 + excess*0.1)。Tier3 なら 1.5倍。
- 3.5: **タワマン・大規模ボーナス**: total_units≥200 または floor≥20 を「タワマン/大規模」と判定。tower_eligible==1 なら +3%（「大規模タワープレミアム」を positive_factors に追加）。tower_eligible==0 かつ非大規模なら adjusted_10y × 0.98（将来性のトレンド抑制）。
- **賃料上昇期待エリア**: rent_growth_rate ≥ 1.08 のとき「賃料上昇期待エリア」を positive_factors に追加。

---

### 4.8 _calculate_yield_floor（収益還元による下値支持価格）

```python
def _calculate_yield_floor(self, rent_monthly: float, cap_rate: float) -> float:
    """
    収益還元価格（推定賃料 ÷ キャップレート）を算出し、Worstシナリオの下値支持価格とする。
    rent_monthly: 月額賃料（円）。10年後賃料を渡す想定。
    cap_rate: キャップレート（年利回り。例: 0.035 = 3.5%）
    """
    if cap_rate <= 0:
        return 0.0
    annual_rent = rent_monthly * 12
    return annual_rent / cap_rate
```

- Worst シナリオ価格がこの値を下回る場合は、この値を採用する（賃料インフレによる下値支持）。

---

### 4.9 predict（ステップ4: マクロシナリオ・金利感応度・災害リスク・Yield Floor・出力）

```python
# シナリオ乗数で3価格を算出
std_val = adjusted_10y * scenario_multipliers.get("standard", 1.0)
best_val = adjusted_10y * best_mult
worst_val = adjusted_10y * scenario_multipliers.get("worst", 0.85)

# 金利上昇感応度（Standard/Worstにのみ適用。郊外ほど購買力低下で減価。Tier3=0.92は2025年12月利上げを反映）
interest_factor = INTEREST_SENSITIVITY_TIER3  # Tier1=1.0, Tier2=0.98, Tier3=0.92
if area_rank == "Tier1":
    interest_factor = INTEREST_SENSITIVITY_TIER1
elif area_rank == "Tier2":
    interest_factor = INTEREST_SENSITIVITY_TIER2
if area_rank == "Tier3":
    risk_factors.append("金利感応度高（Tier3）")
std_val *= interest_factor
worst_val *= interest_factor

# 災害リスクペナルティ（hazard_risk==2: ×0.90, hazard_risk==1: ×0.97）
hazard_risk = int(features.get("hazard_risk", 0) or 0)
if hazard_risk == 2:
    hazard_factor = HAZARD_PENALTY_RED
    risk_factors.append("ハザードリスクあり")
elif hazard_risk == 1:
    hazard_factor = HAZARD_PENALTY_YELLOW
    risk_factors.append("ハザードリスクあり")
else:
    hazard_factor = 1.0
std_val *= hazard_factor
best_val *= hazard_factor
worst_val *= hazard_factor

# 賃料インフレによる下値支持（Yield Floor）: エリア別 rent_growth_rate で10年後賃料を算出し、収益還元価格をWorstの下限に
estimated_rent = features.get("estimated_rent") or 0.0
rent_yield_floor_val = None
if estimated_rent and estimated_rent > 0:
    rent_10y_monthly = estimated_rent * rent_growth_rate  # CSVの rent_growth_rate を使用
    cap_rate = CAP_RATE_TIER1 if area_rank == "Tier1" else (CAP_RATE_TIER2 if area_rank == "Tier2" else CAP_RATE_TIER3)
    rent_yield_floor_val = self._calculate_yield_floor(rent_10y_monthly, cap_rate)
    if worst_val < rent_yield_floor_val:
        worst_val = rent_yield_floor_val

forecast_10y = {
    "standard": int(round(std_val)),
    "best": int(round(best_val)),
    "worst": int(round(worst_val)),
}

return {
    "current_estimated_contract_price": int(round(contract_price)),
    "10y_forecast": forecast_10y,
    "rent_yield_floor": int(round(rent_yield_floor_val)) if rent_yield_floor_val is not None else None,
    "risk_factors": risk_factors,
    "positive_factors": positive_factors,
}
```

- 金利感応度: Tier1=1.0, Tier2=0.98, Tier3=0.92。Standard/Worst にのみ乗算。Tier3 のとき「金利感応度高（Tier3）」を risk_factors に追加。
- **(D) 金利上昇**: 郊外(Group4,5)かつ価格8000万円以上は購買力低下ペナルティ **-3%**（「金利上昇・郊外8000万以上」を risk_factors に追加）。
- 災害リスク: hazard_risk==2 で ×0.90、==1 で ×0.97。該当時「ハザードリスクあり」を追加。
- **(A) Yield Floor（賃料インフレによる下値支持）**: 10年後賃料 = 現在賃料×(1+rent_cagr)^10。10年後収益価格 = 10年後賃料×12/(キャップレート×1.1)。Worst がこの値を下回らないよう max で適用。出力に `rent_yield_floor` を追加。
- **(C) タワマン適性**: tower_regulation_flag==1（高さ制限エリア）は経年減価率1.1倍・「高さ制限エリア」を risk_factors に追加。flag==0 かつ総戸数200戸以上で希少性プレミアム +3%。
- **risk_factors 分析コメント**: 「賃料高成長エリア(Group1-2)」は positive_factors に（インカムゲインによる資産防衛が可能）。「在庫調整局面(都心3区・高額帯)」「高さ制限エリア」は risk_factors に出力。
- **positive_factors**: 「賃料高成長エリア(Group1-2)」「需給逼迫・売り手市場」「大規模タワープレミアム」等。

---

### 4.10 listing_to_property_data（既存 listing の変換）

```python
def listing_to_property_data(listing: dict[str, Any]) -> dict[str, Any]:
    """SUUMO/HOMES スクレイピング結果の辞書を predict() 用の property_data に変換する。"""
    out: dict[str, Any] = {}
    if "price_man" in listing and listing["price_man"] is not None:
        out["listing_price"] = int(listing["price_man"]) * 10000
    if "station_line" in listing and listing["station_line"]:
        out["station_line"] = listing["station_line"]
    if "station_name" in listing and listing["station_name"]:
        out["station_name"] = listing["station_name"]
    for key in ("walk_min", "area_m2", "area_sqm", "built_year", "build_year", "total_units", "floor_position", "floor"):
        if key in listing and listing[key] is not None:
            out[key] = listing[key]
    if "area_m2" in listing and "area_sqm" not in out:
        out["area_sqm"] = listing["area_m2"]
    if "built_year" in listing and "build_year" not in out:
        out["build_year"] = listing["built_year"]
    if "floor_position" in listing and "floor" not in out:
        out["floor"] = listing["floor_position"]
    if "repair_reserve_fund" in listing:
        out["repair_reserve_fund"] = listing["repair_reserve_fund"]
    if "management_fee" in listing:
        out["management_fee"] = listing["management_fee"]
    for key in ("notes", "features", "description", "remarks", "備考", "特徴"):
        if key in listing and listing[key] is not None:
            out[key] = listing[key]
    if "estimated_rent" in listing and listing["estimated_rent"] is not None:
        out["estimated_rent"] = listing["estimated_rent"]
    if "hazard_risk" in listing and listing["hazard_risk"] is not None:
        out["hazard_risk"] = listing["hazard_risk"]
    return out
```

- `price_man` → `listing_price`（万円→円）、`station_line`/`station_name` と面積・築年・階・修繕・管理費・備考系・`estimated_rent`・`hazard_risk` をそのまま引き継ぐ。

---

## 5. 予測ロジックの流れ（対応する実装箇所）

| 順番 | 処理 | 参照データ | 実装箇所 |
|------|------|------------|----------|
| 1 | 売り出し→成約補正 0.958 | なし | 4.4 先頭 |
| 2 | (B) 1.5億〜3億かつ都心3区(inventory<1.0): ×0.92「在庫調整局面」。1.5〜3億その他: ×0.95「高額帯・流動性低下懸念」 | inventory_trend_score | 4.4 |
| 3 | 1.2億〜1.5億: ×0.98、「1.2億円の壁対象」。1.2億以下はペナルティなし | なし | 4.4 |
| 4 | ベースライン経年減価。(C) 高さ制限エリア(tower_regulation_flag==1)は1.1倍。Tier1は0.6%/年、それ以外1.2%/年 | area_rank, rent_cluster_group, tower_regulation_flag | 4.5 |
| 5 | 在庫過多: base_10y 減額、(ip-1)*0.5、「在庫過多エリア」 | inventory_pressure（area_coefficients） | 4.6 |
| 6 | 品薄: base_10y ×1.02 | inventory_pressure | 4.6 |
| 7 | 管理品質: 修繕不足率に応じ最大-15% | guideline_yen_per_sqm（management_guidelines） | 4.7 3a |
| 8 | 40以上50未満: +3% | なし | 4.7 3b |
| 9 | 省エネ・リノベキーワード: +1.5% | 入力の notes/features 等 | 4.7 3c |
| 10 | 徒歩8分以降: 非線形減価、Tier3は1.5倍 | area_rank | 4.7 3d |
| 11 | タワマン・大規模: total_units≥200 または floor≥20 かつ tower_eligible==1 で +3%。tower_eligible==0 かつ非大規模で ×0.98 | total_units, floor, tower_eligible（area_coefficients） | 4.7 3.5 |
| 12 | adjusted_10y × シナリオ乗数。Best は Tier1・1億以上で×0.95 | macro_economic_scenarios, area_rank, contract_price | 4.9 |
| 13 | 金利感応度: Standard/Worst に Tier係数（Tier1=1.0, Tier2=0.98, Tier3=0.92） | area_rank | 4.9 |
| 14 | 災害リスク: hazard_risk==2 で×0.90、==1 で×0.97 | features.hazard_risk | 4.9 |
| 15 | (A) Yield Floor: 10年後賃料=現在×(1+rent_cagr)^10、収益価格=賃料×12/(cap×1.1)。Worst がそれを下回れば採用。rent_yield_floor を出力 | estimated_rent, rent_cagr, area_rank（キャップレート） | 4.8, 4.9 |
| 15b | (D) 金利上昇: Group4,5かつ8000万以上は-3% | rent_cluster_group, contract_price | 4.9 |
| 15c | (C) タワマン適性: 高さ制限エリアは risk「高さ制限エリア」。無規制かつ200戸以上は+3% | tower_regulation_flag, total_units | 4.5, 4.7 |

---

## 6. 出力形式

```json
{
  "current_estimated_contract_price": 81430000,
  "10y_forecast": {
    "standard": 72927487,
    "best": 83866610,
    "worst": 93500000
  },
  "rent_yield_floor": 93500000,
  "risk_factors": ["在庫過多エリア（価格調整リスクあり）"],
  "positive_factors": ["大規模タワープレミアム", "賃料上昇期待エリア"]
}
```

| キー | 説明 |
|------|------|
| `current_estimated_contract_price` | 現在の推定成約価格（円）。ステップ1の補正後価格（流動性ペナルティ込み）。 |
| `10y_forecast` | 10年後の予測価格（円）。standard / best / worst の3シナリオ。 |
| `rent_yield_floor` | 収益還元法による10年後価格の下限（円）。10年後賃料 = 現在賃料×(1+rent_cagr)^10。10年後収益価格 = 10年後賃料×12/(キャップレート×1.1)。推定賃料がある場合のみ算出。**シナリオ整合性**: worst = min(max(worst, rent_yield_floor), standard) で適用。 |
| `risk_factors` | 該当したリスクのリスト。例:「1.2億円の壁対象」「高額帯・流動性低下懸念」「修繕積立金不足」「在庫過多エリア（価格調整リスクあり）」「金利感応度高（Tier3）」「ハザードリスクあり」。 |
| `positive_factors` | ポジティブ要因のリスト。例:「賃料高成長エリア(Group1-2)」(rent_cluster_group≤2 または rent_cagr≥0.05)、「需給逼迫・売り手市場」(inventory_trend_score≥1.03)、「大規模タワープレミアム」(tower_regulation_flag==0 かつ総戸数200戸以上)。 |
| `risk_factors`（分析コメント） | 「在庫調整局面(都心3区・高額帯)」(1.5〜3億かつ inventory_trend_score<1.0)、「高さ制限エリア」(tower_regulation_flag==1)、「金利上昇・郊外8000万以上」(Group4,5かつ8000万以上) 等。 |

---

## 7. 実装ファイル・参照データ一覧

| 種別 | パス |
|------|------|
| 実装 | `scraping-tool/price_predictor.py` |
| バックテスト | `scraping-tool/evaluate.py` |
| 較正係数 | `scraping-tool/data/calibration.json` |
| 区別係数 | `scraping-tool/data/ward_coefficients.csv` |
| 管理目安 | `scraping-tool/data/management_guidelines.csv` |
| マクロシナリオ | `scraping-tool/data/macro_economic_scenarios.csv` |

---

## 8. バックテスト（evaluate.py）

入力（物件特徴）× 実績成約を読み、現在の推定成約価格 vs 実績成約価格で MAE / MAPE / Bias を算出する。

- **入力**: CSV または JSONL。カラムに `listing_price`, `address`（区判定用）, `station_name`, `walk_min`, `area_sqm`, `build_year` 等の物件特徴と、実績成約価格（`actual_contract_price` または `contract_price` 等）が必要。
- **出力**: n（件数）, MAE（円）, MAPE（%）, Bias（円）。Bias > 0 は予測が実績より高めの傾向。

```bash
python3 evaluate.py data/backtest_sample.csv
# --data-dir, --calibration でパス指定可。--use-listing-as-actual で実績カラム無し時は listing_price を実績として使用。
```

以上が現状の実装と参照データに基づく予測ロジックの仕様です。
