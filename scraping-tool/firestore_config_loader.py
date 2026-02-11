#!/usr/bin/env python3
"""
Firestore からスクレイピング条件を取得し、config モジュールをパッチする。

環境変数 FIREBASE_SERVICE_ACCOUNT が設定されている場合、scraping_config/default
ドキュメントを読み取り、config の各定数を上書きする。
取得に失敗した場合やドキュメントが存在しない場合は config.py のデフォルト値を使用。

呼び出し: main.py の最初（他の config を使用するモジュールを import する前）で
load_config_from_firestore() を呼ぶこと。
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

# スクリプト配置が scraping-tool/ である前提
sys.path.insert(0, str(Path(__file__).resolve().parent))

CONFIG_DOC_ID = "default"
COLLECTION_NAME = "scraping_config"


def load_config_from_firestore() -> bool:
    """
    Firestore から scraping_config/default を取得し、config モジュールをパッチする。
    成功時は True、失敗または未設定時は False を返す。
    """
    json_str = os.environ.get("FIREBASE_SERVICE_ACCOUNT")
    if not json_str or not json_str.strip():
        return False

    try:
        import firebase_admin
        from firebase_admin import credentials, firestore
    except ImportError:
        print("# firebase-admin がインストールされていません。config.py のデフォルトを使用します。", file=sys.stderr)
        return False

    try:
        cred_dict = json.loads(json_str)
    except json.JSONDecodeError as e:
        print(f"# FIREBASE_SERVICE_ACCOUNT の JSON パースに失敗: {e}", file=sys.stderr)
        return False

    try:
        try:
            firebase_admin.get_app()
        except ValueError:
            cred = credentials.Certificate(cred_dict)
            firebase_admin.initialize_app(cred)
        db = firestore.client()
    except Exception as e:
        print(f"# Firebase 初期化失敗: {e}", file=sys.stderr)
        return False

    try:
        doc_ref = db.collection(COLLECTION_NAME).document(CONFIG_DOC_ID)
        doc = doc_ref.get()
    except Exception as e:
        print(f"# Firestore 取得失敗: {e}", file=sys.stderr)
        return False

    if not doc.exists:
        return False

    data = doc.to_dict()
    if not data:
        return False

    # config モジュールを import してパッチ
    import config as config_mod

    applied = False

    if "priceMinMan" in data and data["priceMinMan"] is not None:
        config_mod.PRICE_MIN_MAN = int(data["priceMinMan"])
        applied = True
    if "priceMaxMan" in data and data["priceMaxMan"] is not None:
        config_mod.PRICE_MAX_MAN = int(data["priceMaxMan"])
        applied = True
    if "areaMinM2" in data and data["areaMinM2"] is not None:
        config_mod.AREA_MIN_M2 = int(data["areaMinM2"])
        applied = True
    if "areaMaxM2" in data:
        config_mod.AREA_MAX_M2 = int(data["areaMaxM2"]) if data["areaMaxM2"] is not None else None
        applied = True
    if "walkMinMax" in data and data["walkMinMax"] is not None:
        config_mod.WALK_MIN_MAX = int(data["walkMinMax"])
        applied = True
    if "builtYearMin" in data and data["builtYearMin"] is not None:
        try:
            config_mod.BUILT_YEAR_MIN = int(data["builtYearMin"])
            applied = True
        except (ValueError, TypeError):
            pass  # fall back to default
    if "totalUnitsMin" in data and data["totalUnitsMin"] is not None:
        config_mod.TOTAL_UNITS_MIN = int(data["totalUnitsMin"])
        applied = True
    if "layoutPrefixOk" in data and isinstance(data["layoutPrefixOk"], list):
        config_mod.LAYOUT_PREFIX_OK = tuple(str(x) for x in data["layoutPrefixOk"])
        applied = True
    if "allowedLineKeywords" in data and isinstance(data["allowedLineKeywords"], list):
        config_mod.ALLOWED_LINE_KEYWORDS = tuple(str(x) for x in data["allowedLineKeywords"])
        applied = True

    if applied:
        print(f"# Firestore からスクレイピング条件を読み込みました（{CONFIG_DOC_ID}）", file=sys.stderr)

    return applied
