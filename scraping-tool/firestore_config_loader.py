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

from logger import get_logger
logger = get_logger(__name__)

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
        logger.warning("firebase-admin がインストールされていません。config.py のデフォルトを使用します。")
        return False

    try:
        cred_dict = json.loads(json_str)
    except json.JSONDecodeError as e:
        logger.error("FIREBASE_SERVICE_ACCOUNT の JSON パースに失敗: %s", e)
        return False

    try:
        try:
            firebase_admin.get_app()
        except ValueError:
            cred = credentials.Certificate(cred_dict)
            firebase_admin.initialize_app(cred)
        db = firestore.client()
    except Exception as e:
        logger.error("Firebase 初期化失敗: %s", e)
        return False

    try:
        doc_ref = db.collection(COLLECTION_NAME).document(CONFIG_DOC_ID)
        doc = doc_ref.get()
    except Exception as e:
        logger.error("Firestore 取得失敗: %s", e)
        return False

    if not doc.exists:
        return False

    data = doc.to_dict()
    if not data:
        return False

    # config モジュールを import してパッチ
    import config as config_mod
    applied = config_mod.apply_runtime_overrides(data)

    if applied:
        logger.info("Firestore からスクレイピング条件を読み込みました（%s）", CONFIG_DOC_ID)

    return applied
