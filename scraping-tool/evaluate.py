"""
バックテスト評価: 物件特徴 × 実績成約を読み、MAE / MAPE / Bias を算出する。

入力: CSV または JSON Lines（物件特徴 + 実績成約価格）
  - カラム: listing_price(円), station_name, walk_min, area_sqm, build_year, ...
  - 実績成約: actual_contract_price または contract_price（円）
出力: MAE（円）, MAPE（%）, Bias（円）
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from price_predictor import MansionPricePredictor


# 実績成約価格のカラム名候補
ACTUAL_PRICE_COLUMNS = ("actual_contract_price", "contract_price", "成約価格", "actual_price")


def _row_to_property_data(row: pd.Series, columns: list[str]) -> dict:
    """DataFrame の1行を predict 用の property_data に変換する。"""
    d = {}
    for col in columns:
        if col in row.index and pd.notna(row.get(col)):
            val = row[col]
            if col in ("listing_price", "price_man", "actual_contract_price", "contract_price", "成約価格", "actual_price"):
                try:
                    val = float(val)
                    if col == "price_man":
                        val = int(val) * 10000 if val == val else None
                except (TypeError, ValueError):
                    pass
            d[col] = val
    if "price_man" in d and "listing_price" not in d:
        d["listing_price"] = int(float(d["price_man"])) * 10000
    if "area_m2" in d and "area_sqm" not in d:
        d["area_sqm"] = d["area_m2"]
    if "built_year" in d and "build_year" not in d:
        d["build_year"] = d["built_year"]
    if "floor_position" in d and "floor" not in d:
        d["floor"] = d["floor_position"]
    return d


def _find_actual_price_column(df: pd.DataFrame) -> str:
    for c in ACTUAL_PRICE_COLUMNS:
        if c in df.columns:
            return c
    raise KeyError(f"実績成約価格のカラムが見つかりません。いずれかが必要: {ACTUAL_PRICE_COLUMNS}")


def run_evaluate(
    input_path: Path,
    data_dir: Path | None = None,
    calibration_path: Path | None = None,
    use_listing_as_actual_if_missing: bool = False,
) -> dict:
    """
    入力ファイルを読み、予測を実行し、MAE/MAPE/Bias を返す。

    - input_path: CSV または .jsonl。CSV はヘッダー必須。
    - data_dir: 係数CSVのディレクトリ（省略時は scraping-tool/data）
    - calibration_path: calibration.json のパス（省略時は data_dir/calibration.json）
    - use_listing_as_actual_if_missing: 実績成約カラムが無い場合、listing_price を実績として使う（検証用）
    """
    data_dir = data_dir or ROOT / "data"
    predictor = MansionPricePredictor(data_dir=data_dir, calibration_path=calibration_path)
    predictor.load_data()

    suffix = input_path.suffix.lower()
    if suffix == ".csv":
        df = pd.read_csv(input_path, encoding="utf-8")
    elif suffix == ".jsonl" or suffix == ".ndjson":
        rows = []
        with open(input_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                rows.append(json.loads(line))
        df = pd.DataFrame(rows)
    else:
        raise ValueError(f"未対応の拡張子: {suffix}. .csv または .jsonl を指定してください。")

    if df.empty:
        return {"n": 0, "mae": None, "mape": None, "bias": None, "message": "入力が0件です。"}

    try:
        actual_col = _find_actual_price_column(df)
    except KeyError as e:
        if use_listing_as_actual_if_missing and "listing_price" in df.columns:
            actual_col = "listing_price"
        else:
            raise e

    predictions = []
    actuals = []

    for _, row in df.iterrows():
        actual_val = row.get(actual_col)
        if pd.isna(actual_val):
            continue
        try:
            actual_yen = int(float(actual_val))
        except (TypeError, ValueError):
            continue
        if actual_yen <= 0:
            continue
        prop = _row_to_property_data(row, list(df.columns))
        if not prop.get("listing_price") and not prop.get("price_man"):
            continue
        if prop.get("listing_price") is None and prop.get("price_man") is not None:
            prop["listing_price"] = int(float(prop["price_man"])) * 10000
        out = predictor.predict(prop)
        pred = out.get("current_estimated_contract_price") or 0
        if pred <= 0:
            continue
        predictions.append(pred)
        actuals.append(actual_yen)

    if not predictions:
        return {"n": 0, "mae": None, "mape": None, "bias": None, "message": "有効な予測が0件でした。"}

    n = len(predictions)
    errors = [p - a for p, a in zip(predictions, actuals)]
    mae = sum(abs(e) for e in errors) / n
    mape = sum(abs(e) / max(a, 1) for e, a in zip(errors, actuals)) / n * 100.0
    bias = sum(errors) / n

    return {
        "n": len(predictions),
        "mae": round(mae, 0),
        "mape": round(mape, 2),
        "bias": round(bias, 0),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="物件予測のバックテスト: MAE/MAPE/Bias を算出")
    parser.add_argument("input", type=Path, help="入力 CSV または JSONL（物件特徴 + actual_contract_price）")
    parser.add_argument("--data-dir", type=Path, default=None, help="data ディレクトリ")
    parser.add_argument("--calibration", type=Path, default=None, help="calibration.json のパス")
    parser.add_argument("--use-listing-as-actual", action="store_true", help="実績カラムが無い場合 listing_price を実績とする")
    args = parser.parse_args()

    result = run_evaluate(
        args.input,
        data_dir=args.data_dir,
        calibration_path=args.calibration,
        use_listing_as_actual_if_missing=args.use_listing_as_actual,
    )
    print("n:", result["n"])
    if result.get("message"):
        print("message:", result["message"])
    if result["mae"] is not None:
        print("MAE (円):", result["mae"])
        print("MAPE (%):", result["mape"])
        print("Bias (円):", result["bias"])
    sys.exit(0 if result["n"] else 1)


if __name__ == "__main__":
    main()
