"""
共通ユーティリティ。future_estate_predictor と price_predictor で重複するロジックを集約。
"""

import math
import re
from typing import Optional

# ローン計算の共通定数（50年変動金利・金利0.8%・元利均等・iOS アプリと統一）
LOAN_YEARS = 50
LOAN_ANNUAL_RATE = 0.008  # 0.8%
LOAN_MONTHS = LOAN_YEARS * 12
LOAN_MONTHS_AFTER_10Y = 10 * 12


def ward_from_address(address: Optional[str]) -> Optional[str]:
    """
    住所文字列から区名（〇〇区）を抽出する。
    例: "東京都千代田区神田神保町1-1" → "千代田区", "江東区豊洲3-2" → "江東区"
    """
    if not address or not str(address).strip():
        return None
    s = str(address).strip()
    m = re.search(r"(?:東京都)?([一-龥ぁ-んァ-ン]+区)", s)
    if m:
        return m.group(1).strip()
    return None


def calc_loan_residual_10y_yen(
    purchase_price_yen: float,
    annual_rate: float = LOAN_ANNUAL_RATE,
    total_months: int = LOAN_MONTHS,
    elapsed_months: int = LOAN_MONTHS_AFTER_10Y,
) -> float:
    """
    元利均等で elapsed_months 経過後のローン残高（円）を返す。
    デフォルト: 50年・0.8%・10年経過時点の残高。
    """
    if purchase_price_yen <= 0:
        return 0.0
    price_man = purchase_price_yen / 10000
    n = total_months
    r = annual_rate / 12
    if r <= 0:
        return purchase_price_yen * (1 - elapsed_months / n)
    monthly = price_man * r * math.pow(1 + r, n) / (math.pow(1 + r, n) - 1)
    k = elapsed_months
    balance_man = price_man * math.pow(1 + r, k) - monthly * (math.pow(1 + r, k) - 1) / r
    return max(0.0, balance_man) * 10000
