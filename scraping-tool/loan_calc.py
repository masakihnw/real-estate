"""
50年変動金利ローン・頭金なし・諸経費込みの月額・総額計算。
修繕積立など諸経費は月3.5万円とする。
"""

import math
from dataclasses import dataclass
from typing import Optional

# カスタマイズ可能な定数（含み益・資産性のローン残高試算と共通: 50年変動金利・金利1%）
LOAN_YEARS = 50
ANNUAL_RATE_VARIABLE = 0.01   # 変動金利 年1%
MONTHLY_OTHER_EXPENSES_MAN = 3.5  # 修繕積立など諸経費（万円/月）


@dataclass
class LoanResult:
    """50年ローン（頭金0・諸経費込み）の計算結果。"""
    monthly_total_man: float   # 毎月の支払額（ローン+諸経費）（万円）
    total_man: float           # 50年支払総額（万円）


def calc_50year_monthly_and_total(price_man: Optional[float]) -> Optional[LoanResult]:
    """
    50年変動金利・頭金なしで購入した場合の毎月の支払額と50年総額を計算する。
    諸経費は月3.5万円を加算。

    引数:
      price_man: 購入価格（万円）。None または 0 以下は None を返す。

    返り値:
      LoanResult(月額万円, 50年総額万円)。計算不可時は None。
    """
    if price_man is None or price_man <= 0:
        return None
    n = LOAN_YEARS * 12  # 600
    r = ANNUAL_RATE_VARIABLE / 12  # 月利
    if r <= 0:
        monthly_mortgage = price_man / n
    else:
        # 元利均等: 月返済 = P * r * (1+r)^n / ((1+r)^n - 1)
        monthly_mortgage = price_man * r * math.pow(1 + r, n) / (math.pow(1 + r, n) - 1)
    monthly_total = monthly_mortgage + MONTHLY_OTHER_EXPENSES_MAN
    total = monthly_total * n
    return LoanResult(
        monthly_total_man=round(monthly_total, 2),
        total_man=round(total, 0),
    )


def format_loan_monthly(monthly_man: Optional[float]) -> str:
    """月額支払をレポート用文字列に。"""
    if monthly_man is None or monthly_man <= 0:
        return "-"
    if monthly_man >= 100:
        return f"{monthly_man:.0f}万円/月"
    if monthly_man >= 10:
        return f"{monthly_man:.1f}万円/月"
    return f"{monthly_man:.2f}万円/月"


def format_loan_total(total_man: Optional[float]) -> str:
    """50年支払総額をレポート用文字列に。"""
    if total_man is None or total_man <= 0:
        return "-"
    if total_man >= 10000:
        oku = int(total_man // 10000)
        man = int(total_man % 10000)
        if man == 0:
            return f"{oku}億円"
        return f"{oku}億{man}万円"
    return f"{int(total_man)}万円"


def get_loan_display_for_listing(price_man: Optional[float]) -> tuple[str, str]:
    """
    物件の価格から50年ローン月額・総額の表示用文字列を返す。
    (月額表示, 総額表示)
    """
    res = calc_50year_monthly_and_total(price_man)
    if not res:
        return "-", "-"
    return format_loan_monthly(res.monthly_total_man), format_loan_total(res.total_man)
