"""スクレイパーのパース成功率メトリクス収集。

HTML構造変更・botブロックによるサイレントなデータ品質低下を早期検知するための
プロセス内メトリクス。各スクレイパーがパース結果を記録し、main.py 実行末尾で
JSON に書き出す。slack_notify が閾値超過ソースを警告セクションとして通知する。

SUUMO のパース0件即break のような「気づくのが1ヶ月遅れる」障害の再発防止策。
"""

from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

from logger import get_logger

logger = get_logger(__name__)

# パース失敗率がこの値以上のソースをアラート対象にする
FAILURE_RATE_THRESHOLD = 0.30

# 空ページ（パース0件）がこの回数以上のソースもアラート対象
EMPTY_PAGE_THRESHOLD = 3

# 終端理由。スクレイパーは区/リストの巡回ループを抜けるたびに record_finish で記録する。
# - completed:         正常終端（一覧の末尾に到達）
# - early_exit:        連続Nページ通過0件による早期打ち切り（正常な省力化）
# - safety_limit:      安全上限ページ到達。上限超のページを取りこぼしている可能性
# - timeout:           タイムリミット到達。未巡回ページを取りこぼしている
# - waf_abort:         WAF/CAPTCHA連続検知による放棄
# - empty_parse_abort: 1件もパースできずに停止（botブロック/構造変更の可能性）
# - fetch_error:       取得例外による中断
NORMAL_FINISH_REASONS = frozenset({"completed", "early_exit"})
ABNORMAL_FINISH_REASONS = frozenset(
    {"safety_limit", "timeout", "waf_abort", "empty_parse_abort", "fetch_error"}
)
FINISH_REASONS = NORMAL_FINISH_REASONS | ABNORMAL_FINISH_REASONS

# 「一覧を最後まで巡回できなかった」ことを意味する終端理由。
# これらが記録されたランでは未巡回ページの物件が「見つからなかった」扱いになるため、
# 掲載終了判定（grace period の miss 加算）に使ってはいけない（フェイルクローズ）。
TRUNCATED_FINISH_REASONS = ABNORMAL_FINISH_REASONS

# 古いメトリクスファイルで掲載終了判定をゲートしないための鮮度上限
METRICS_MAX_AGE_HOURS = 24

METRICS_PATH = Path(__file__).resolve().parent / "results" / "scraper_metrics.json"


def _new_entry() -> dict:
    return {"parsed": 0, "parse_failures": 0, "empty_pages": 0, "finish_reasons": {}}


_metrics: dict[str, dict] = defaultdict(_new_entry)


def record(source: str, *, parsed: int = 0, parse_failures: int = 0, empty_pages: int = 0) -> None:
    """ソースごとのパース結果を加算する。"""
    entry = _metrics[source]
    entry["parsed"] += parsed
    entry["parse_failures"] += parse_failures
    entry["empty_pages"] += empty_pages


def record_finish(source: str, reason: str) -> None:
    """巡回ループの終端理由を記録する（区単位のスクレイパーは区ごとに1回）。"""
    if reason not in FINISH_REASONS:
        raise ValueError(f"未知の終端理由: {reason}（{sorted(FINISH_REASONS)} のいずれか）")
    reasons = _metrics[source]["finish_reasons"]
    reasons[reason] = reasons.get(reason, 0) + 1


def reset() -> None:
    _metrics.clear()


def get_all() -> dict[str, dict]:
    return {
        k: {**v, "finish_reasons": dict(v["finish_reasons"])}
        for k, v in _metrics.items()
    }


def failure_rate(entry: dict) -> float:
    """パース失敗率（失敗 / (成功+失敗)）。試行0なら0.0。"""
    total = entry.get("parsed", 0) + entry.get("parse_failures", 0)
    if total == 0:
        return 0.0
    return entry.get("parse_failures", 0) / total


def _has_activity(entry: dict) -> bool:
    """そのソースが今回の実行で1度でも走った形跡があるか。"""
    return bool(
        entry.get("parsed", 0)
        or entry.get("parse_failures", 0)
        or entry.get("empty_pages", 0)
        or entry.get("finish_reasons", {})
    )


def health_alerts(metrics: dict[str, dict] | None = None) -> list[str]:
    """閾値超過したソースの警告メッセージ一覧を返す。"""
    metrics = metrics if metrics is not None else get_all()
    alerts: list[str] = []
    for source, entry in sorted(metrics.items()):
        reasons = entry.get("finish_reasons", {})
        abnormal = {r: n for r, n in sorted(reasons.items()) if r in ABNORMAL_FINISH_REASONS}

        # 走った形跡があるのにパース0件 = 媒体全損の最有力シグナル
        # （athome が全23区0件・無警告で1ヶ月気づかなかった事故の再発防止）
        if entry.get("parsed", 0) == 0 and _has_activity(entry):
            detail = "、".join(f"{r}×{n}" for r, n in sorted(reasons.items())) or "終端理由記録なし"
            alerts.append(
                f"{source}: 1件もパースできずに終了（媒体全損の可能性） — 終端: {detail}"
            )
            # 全損アラートに異常終端の内訳を含めたため、下の異常終端アラートは重複出力しない
            abnormal = {}

        if abnormal:
            detail = "、".join(f"{r}×{n}" for r, n in abnormal.items())
            alerts.append(
                f"{source}: 異常終端 {detail} — 残ページ取りこぼしの可能性"
            )

        rate = failure_rate(entry)
        if rate >= FAILURE_RATE_THRESHOLD and entry.get("parse_failures", 0) > 0:
            alerts.append(
                f"{source}: パース失敗率 {rate:.0%}"
                f"（{entry['parse_failures']}/{entry['parsed'] + entry['parse_failures']}件）"
                " — HTML構造変更の可能性"
            )
        if entry.get("empty_pages", 0) >= EMPTY_PAGE_THRESHOLD:
            alerts.append(
                f"{source}: パース0件ページが {entry['empty_pages']} 回"
                " — botブロック/構造変更の可能性"
            )
    return alerts


def save(path: Path | None = None) -> None:
    """メトリクスを JSON に書き出す（slack_notify / 掲載終了判定が読む）。"""
    target = path or METRICS_PATH
    target.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "metrics": get_all(),
        "alerts": health_alerts(),
        "saved_at": datetime.now(timezone.utc).isoformat(),
    }
    with open(target, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    if data["alerts"]:
        for alert in data["alerts"]:
            logger.warning("scraper health: %s", alert)
    else:
        logger.info("scraper health: 全ソース正常（%d ソース）", len(data["metrics"]))


def load(path: Path | None = None) -> dict:
    """書き出されたメトリクスを読み込む。なければ空。"""
    target = path or METRICS_PATH
    if not target.exists():
        return {"metrics": {}, "alerts": []}
    try:
        with open(target, encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        logger.warning("scraper_metrics 読み込み失敗: %s", e)
        return {"metrics": {}, "alerts": []}


def _is_fresh(data: dict) -> bool:
    """メトリクスが今回のラン由来とみなせる鮮度か（saved_at が24時間以内）。"""
    saved_at = data.get("saved_at")
    if not saved_at:
        return False
    try:
        ts = datetime.fromisoformat(saved_at)
    except ValueError:
        return False
    age = datetime.now(timezone.utc) - ts
    return age.total_seconds() < METRICS_MAX_AGE_HOURS * 3600


def source_scan_truncated(source: str, metrics_data: dict | None = None) -> dict[str, int]:
    """ソースの一覧巡回が途中で打ち切られた形跡（終端理由→回数）を返す。

    空 dict = 完走（または判定材料なし）。打ち切りが記録されたランでは、
    未巡回ページの物件を「掲載終了」と誤判定しないよう、呼び出し側
    （db.py / supabase_sync.py の grace period）は miss 加算をスキップする。

    メトリクスファイルが古い（前回ラン以前の）場合はゲートしない
    （古い打ち切り記録で掲載終了判定が永久に止まるのを防ぐ）。
    鮮度チェックは引数渡し（metrics_data 指定）でも一貫して適用する。
    """
    data = metrics_data if metrics_data is not None else load()
    if not _is_fresh(data):
        return {}
    entry = (data.get("metrics") or {}).get(source) or {}
    reasons = entry.get("finish_reasons") or {}
    return {r: int(n) for r, n in reasons.items() if r in TRUNCATED_FINISH_REASONS and n}
