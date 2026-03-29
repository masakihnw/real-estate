#!/usr/bin/env python3
"""
ScrapingConfigMetadata.json の defaults を Firestore scraping_config/default に反映する。

iOS の ScrapingConfig.toFirestoreData() と同じキーを書き込む（GitHub Actions / ローカルから実行可）。

前提:
  環境変数 FIREBASE_SERVICE_ACCOUNT にサービスアカウント JSON（文字列）を設定すること。
  （upload_scraping_log.py と同じ認証方式）

使い方:
  cd scraping-tool && python3 push_scraping_config_to_firestore.py
"""

from __future__ import annotations

import json
import os
import sys
from datetime import date
from pathlib import Path

# scraping-tool をパスに含める（logger 未使用でも import 整合のため）
sys.path.insert(0, str(Path(__file__).resolve().parent))

_METADATA_PATH = Path(__file__).resolve().parents[1] / "real-estate-ios" / "RealEstateApp" / "ScrapingConfigMetadata.json"
_COLLECTION = "scraping_config"
_DOCUMENT_ID = "default"


def _load_metadata() -> dict:
    raw = _METADATA_PATH.read_text(encoding="utf-8")
    return json.loads(raw)


def _built_year_min(defaults: dict, constraints: dict) -> int:
    year = date.today().year
    off = int(defaults["builtYearMinOffsetYears"])
    c = constraints["builtYearMinOffsetYears"]
    off = min(max(int(c["min"]), off), int(c["max"]))
    max_year = year - max(0, int(constraints["builtYearMin"]["maxOffsetFromCurrentYear"]))
    raw = year - off
    lo = int(constraints["builtYearMin"]["min"])
    return min(max(lo, raw), max_year)


def build_document(meta: dict) -> dict:
    defaults = meta["defaults"]
    constraints = meta["constraints"]
    doc: dict = {
        "priceMinMan": int(defaults["priceMinMan"]),
        "priceMaxMan": int(defaults["priceMaxMan"]),
        "areaMinM2": int(defaults["areaMinM2"]),
        "walkMinMax": int(defaults["walkMinMax"]),
        "builtYearMin": _built_year_min(defaults, constraints),
        "totalUnitsMin": int(defaults["totalUnitsMin"]),
        "layoutPrefixOk": list(defaults["layoutPrefixOk"]),
        "allowedLineKeywords": list(defaults.get("allowedLineKeywords") or []),
        "allowedStations": list(defaults.get("allowedStations") or []),
    }
    am = defaults.get("areaMaxM2")
    if am is not None:
        doc["areaMaxM2"] = int(am)
    return doc


def main() -> int:
    json_str = os.environ.get("FIREBASE_SERVICE_ACCOUNT", "").strip()
    if not json_str:
        print("FIREBASE_SERVICE_ACCOUNT が未設定です。", file=sys.stderr)
        print("GitHub のシークレットと同じ JSON を環境変数に設定してから再実行してください。", file=sys.stderr)
        return 1

    if not _METADATA_PATH.is_file():
        print(f"メタデータが見つかりません: {_METADATA_PATH}", file=sys.stderr)
        return 1

    try:
        import firebase_admin
        from firebase_admin import credentials, firestore
    except ImportError:
        print("firebase-admin をインストールしてください: pip install firebase-admin", file=sys.stderr)
        return 1

    try:
        cred_dict = json.loads(json_str)
    except json.JSONDecodeError as e:
        print(f"FIREBASE_SERVICE_ACCOUNT の JSON パースに失敗: {e}", file=sys.stderr)
        return 1

    meta = _load_metadata()
    doc = build_document(meta)
    doc["updatedAt"] = firestore.SERVER_TIMESTAMP
    doc["updatedBy"] = "push_scraping_config_to_firestore.py"
    doc["updatedByName"] = "metadata sync (admin)"

    try:
        try:
            firebase_admin.get_app()
        except ValueError:
            cred = credentials.Certificate(cred_dict)
            firebase_admin.initialize_app(cred)
        db = firestore.client()
    except Exception as e:
        print(f"Firebase 初期化失敗: {e}", file=sys.stderr)
        return 1

    try:
        db.collection(_COLLECTION).document(_DOCUMENT_ID).set(doc)
    except Exception as e:
        print(f"Firestore 書き込み失敗: {e}", file=sys.stderr)
        return 1

    # ログ用（タイムスタンプはサーバー側）
    preview = {k: v for k, v in doc.items() if k not in ("updatedAt",)}
    print("scraping_config/default を更新しました。")
    print(json.dumps(preview, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
