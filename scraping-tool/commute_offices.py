#!/usr/bin/env python3
"""通勤先オフィス定義（住所・座標・名称）のローダ。

実運用の住所・座標・法人正式名称はリポジトリに置かず、環境変数
``COMMUTE_OFFICES_JSON``（または Supabase）から注入する。リポジトリには
個人を特定しないプレースホルダ既定値のみを保持する。

``COMMUTE_OFFICES_JSON`` の例::

    {"playground": {"name": "◯◯株式会社", "address": "東京都...",
                     "lat": 35.0, "lon": 139.0},
     "m3career": {"name": "△△株式会社", "address": "東京都...",
                   "lat": 35.0, "lon": 139.0}}
"""

from __future__ import annotations

import json
import os

from logger import get_logger

logger = get_logger(__name__)

# プレースホルダ既定値（実住所・座標・法人正式名は含めない）。
# slug（playground / m3career）はロゴアセット等の製品機能として保持する。
_PLACEHOLDER_OFFICES: dict[str, dict] = {
    "playground": {"name": "オフィスA", "short": "PG", "address": "東京都（住所未設定）", "lat": 0.0, "lon": 0.0},
    "m3career": {"name": "オフィスB", "short": "M3", "address": "東京都（住所未設定）", "lat": 0.0, "lon": 0.0},
}

_ENV_VAR = "COMMUTE_OFFICES_JSON"


def _merge(base: dict[str, dict], override: dict) -> dict[str, dict]:
    out = {k: dict(v) for k, v in base.items()}
    for key, vals in (override or {}).items():
        if not isinstance(vals, dict):
            continue
        out.setdefault(key, {}).update(vals)
    return out


def load_office_locations() -> dict[str, dict]:
    """通勤先オフィスの住所・座標・名称を返す（環境変数 override 対応）。

    ``COMMUTE_OFFICES_JSON`` が未設定/不正な場合はプレースホルダを返す。
    """
    raw = os.environ.get(_ENV_VAR, "").strip()
    if not raw:
        return {k: dict(v) for k, v in _PLACEHOLDER_OFFICES.items()}
    try:
        override = json.loads(raw)
    except json.JSONDecodeError as e:
        logger.warning("%s の解析に失敗、プレースホルダを使用: %s", _ENV_VAR, e)
        return {k: dict(v) for k, v in _PLACEHOLDER_OFFICES.items()}
    return _merge(_PLACEHOLDER_OFFICES, override)
