#!/usr/bin/env python3
"""
enrichment カバレッジを監視し、大幅な低下を検出して Slack アラートを送信する。

使い方:
  python3 scripts/check_enrichment_health.py \
    --current results/latest.json \
    --previous results/previous.json

環境変数:
  SLACK_WEBHOOK_URL  — 設定時のみ Slack 通知を送信
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from logger import get_logger
from slack_notify import send_slack_message

logger = get_logger(__name__)

MONITORED_FIELDS: dict[str, float] = {
    "ss_lookup_status": 0.30,
    "hazard_info": 0.50,
    "commute_info": 0.30,
    "commute_info_v2": 0.30,
    "reinfolib_market_data": 0.20,
    "estat_population_data": 0.20,
    "extracted_features": 0.30,
    "mansion_review_data": 0.10,
    "floor_plan_images": 0.10,
    "dedup_confidence": 0.30,
    "image_categories": 0.30,
    "price_fairness_score": 0.20,
    "ai_recommendation_score": 0.20,
}

DROP_THRESHOLD_PCT = 30


@dataclass(frozen=True)
class FieldCoverage:
    field: str
    count: int
    total: int

    @property
    def pct(self) -> float:
        return (self.count / self.total * 100) if self.total > 0 else 0.0


@dataclass
class HealthReport:
    current_total: int = 0
    previous_total: int = 0
    coverages: list[FieldCoverage] = field(default_factory=list)
    previous_coverages: dict[str, float] = field(default_factory=dict)
    alerts: list[str] = field(default_factory=list)

    @property
    def has_alerts(self) -> bool:
        return len(self.alerts) > 0


def compute_coverage(listings: list[dict], fields: list[str]) -> list[FieldCoverage]:
    total = len(listings)
    results: list[FieldCoverage] = []
    for f in fields:
        count = sum(1 for item in listings if item.get(f) is not None)
        results.append(FieldCoverage(field=f, count=count, total=total))
    return results


def check_health(
    current: list[dict],
    previous: list[dict] | None,
    monitored: dict[str, float] | None = None,
) -> HealthReport:
    if monitored is None:
        monitored = MONITORED_FIELDS

    report = HealthReport(current_total=len(current))
    report.coverages = compute_coverage(current, list(monitored.keys()))

    if previous is not None:
        report.previous_total = len(previous)
        prev_coverages = compute_coverage(previous, list(monitored.keys()))
        report.previous_coverages = {c.field: c.pct for c in prev_coverages}

    for cov in report.coverages:
        min_pct = monitored.get(cov.field, 0.0) * 100

        if cov.pct < min_pct:
            report.alerts.append(
                f"[LOW] {cov.field}: {cov.pct:.1f}% (最低基準 {min_pct:.0f}% 未満)"
            )

        prev_pct = report.previous_coverages.get(cov.field)
        if prev_pct is not None and prev_pct > 0:
            drop = prev_pct - cov.pct
            if drop >= DROP_THRESHOLD_PCT:
                report.alerts.append(
                    f"[DROP] {cov.field}: {prev_pct:.1f}% → {cov.pct:.1f}% "
                    f"({drop:.1f}pp 低下)"
                )

    return report


def format_report(report: HealthReport) -> str:
    lines = [f"Enrichment Health Check ({report.current_total} listings)"]
    lines.append("=" * 50)

    for cov in report.coverages:
        prev_str = ""
        prev_pct = report.previous_coverages.get(cov.field)
        if prev_pct is not None:
            diff = cov.pct - prev_pct
            arrow = "+" if diff >= 0 else ""
            prev_str = f" ({arrow}{diff:.1f}pp)"
        lines.append(f"  {cov.field}: {cov.pct:.1f}%{prev_str}")

    if report.alerts:
        lines.append("")
        lines.append("ALERTS:")
        for alert in report.alerts:
            lines.append(f"  {alert}")

    return "\n".join(lines)


def format_slack_alert(report: HealthReport) -> str:
    lines = [":warning: *Enrichment カバレッジアラート*"]
    lines.append(f"対象: {report.current_total} 件")
    lines.append("")
    for alert in report.alerts:
        lines.append(f"• {alert}")
    lines.append("")
    lines.append("カバレッジ一覧:")
    for cov in report.coverages:
        prev_pct = report.previous_coverages.get(cov.field)
        if prev_pct is not None:
            lines.append(f"  {cov.field}: {prev_pct:.0f}% → {cov.pct:.0f}%")
        else:
            lines.append(f"  {cov.field}: {cov.pct:.0f}%")
    return "\n".join(lines)


def load_json(path: Path) -> list[dict] | None:
    if not path.exists():
        return None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, list):
            return data
    except (json.JSONDecodeError, OSError) as e:
        logger.error(f"JSON 読み込み失敗: {path}: {e}")
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description="enrichment カバレッジ監視")
    parser.add_argument("--current", required=True, help="現在の latest.json")
    parser.add_argument("--previous", default=None, help="前回の previous.json")
    args = parser.parse_args()

    current = load_json(Path(args.current))
    if current is None:
        logger.error(f"current ファイルを読み込めません: {args.current}")
        sys.exit(1)

    previous = load_json(Path(args.previous)) if args.previous else None

    report = check_health(current, previous)
    logger.info(format_report(report))

    if report.has_alerts:
        webhook_url = os.environ.get("SLACK_ALERT_WEBHOOK_URL") or os.environ.get("SLACK_WEBHOOK_URL", "")
        if webhook_url:
            msg = format_slack_alert(report)
            send_slack_message(webhook_url, msg)
            logger.info("Slack アラートを送信しました")
        else:
            logger.warning("SLACK_WEBHOOK_URL 未設定のため Slack 通知をスキップ")
        sys.exit(1)

    logger.info("カバレッジに問題なし")


if __name__ == "__main__":
    main()
