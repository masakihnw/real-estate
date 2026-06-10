"""スクレイパーのパース成功率メトリクス収集。

HTML構造変更・botブロックによるサイレントなデータ品質低下を早期検知するための
プロセス内メトリクス。各スクレイパーがパース結果を記録し、main.py 実行末尾で
JSON に書き出す。slack_notify が閾値超過ソースを警告セクションとして通知する。

SUUMO のパース0件即break のような「気づくのが1ヶ月遅れる」障害の再発防止策。
"""

from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

from logger import get_logger

logger = get_logger(__name__)

# パース失敗率がこの値以上のソースをアラート対象にする
FAILURE_RATE_THRESHOLD = 0.30

# 空ページ（パース0件）がこの回数以上のソースもアラート対象
EMPTY_PAGE_THRESHOLD = 3

METRICS_PATH = Path(__file__).resolve().parent / "results" / "scraper_metrics.json"


def _new_entry() -> dict:
    return {"parsed": 0, "parse_failures": 0, "empty_pages": 0}


_metrics: dict[str, dict] = defaultdict(_new_entry)


def record(source: str, *, parsed: int = 0, parse_failures: int = 0, empty_pages: int = 0) -> None:
    """ソースごとのパース結果を加算する。"""
    entry = _metrics[source]
    entry["parsed"] += parsed
    entry["parse_failures"] += parse_failures
    entry["empty_pages"] += empty_pages


def reset() -> None:
    _metrics.clear()


def get_all() -> dict[str, dict]:
    return {k: dict(v) for k, v in _metrics.items()}


def failure_rate(entry: dict) -> float:
    """パース失敗率（失敗 / (成功+失敗)）。試行0なら0.0。"""
    total = entry.get("parsed", 0) + entry.get("parse_failures", 0)
    if total == 0:
        return 0.0
    return entry.get("parse_failures", 0) / total


def health_alerts(metrics: dict[str, dict] | None = None) -> list[str]:
    """閾値超過したソースの警告メッセージ一覧を返す。"""
    metrics = metrics if metrics is not None else get_all()
    alerts: list[str] = []
    for source, entry in sorted(metrics.items()):
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
    """メトリクスを JSON に書き出す（slack_notify が読む）。"""
    target = path or METRICS_PATH
    target.parent.mkdir(parents=True, exist_ok=True)
    data = {"metrics": get_all(), "alerts": health_alerts()}
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
