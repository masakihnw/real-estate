#!/usr/bin/env python3
"""
Claude API 基盤モジュール。

Batch API 対応、レスポンスキャッシュ（SQLite）、リトライ、Prompt Caching を提供。
全 Claude enricher モジュールはこのクライアントを通じて API を呼び出す。
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from logger import get_logger

logger = get_logger(__name__)

DEFAULT_CACHE_DB = str(Path(__file__).resolve().parent / "data" / "claude_cache.db")
_CREDIT_EXHAUSTED_FLAG = Path(__file__).resolve().parent / "data" / ".claude_credit_exhausted"
DEFAULT_MODEL = "claude-haiku-4-5-20251001"
SONNET_MODEL = "claude-sonnet-4-20250514"


class CreditError(Exception):
    """API クレジット不足。ジョブを即座に失敗させる。"""


def _is_credit_error(exc: Exception) -> bool:
    msg = str(exc).lower()
    return "credit balance" in msg or "payment required" in msg or "usage limits" in msg

_CACHE_SCHEMA = """
CREATE TABLE IF NOT EXISTS claude_cache (
    cache_key TEXT PRIMARY KEY,
    module TEXT NOT NULL,
    result_json TEXT NOT NULL,
    model TEXT NOT NULL,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%S+09:00', 'now', '+9 hours'))
);
CREATE INDEX IF NOT EXISTS idx_claude_cache_module ON claude_cache(module);
"""


@dataclass
class BatchRequest:
    custom_id: str
    messages: list[dict]
    system: str = ""
    model: str = DEFAULT_MODEL
    max_tokens: int = 1024
    temperature: float = 0.0


@dataclass
class BatchResult:
    custom_id: str
    content: str = ""
    input_tokens: int = 0
    output_tokens: int = 0
    error: Optional[str] = None


class ClaudeClient:
    """Claude API クライアント。Batch API + キャッシュ + リトライ。"""

    def __init__(
        self,
        api_key: Optional[str] = None,
        cache_db_path: str = DEFAULT_CACHE_DB,
        daily_budget_usd: float = 5.0,
    ):
        self._api_key = api_key or os.environ.get("ANTHROPIC_API_KEY")
        if not self._api_key:
            raise ValueError("ANTHROPIC_API_KEY が設定されていません")

        self._daily_budget_usd = daily_budget_usd
        self._cache_db_path = cache_db_path
        self._init_cache_db()

        try:
            import anthropic
            self._client = anthropic.Anthropic(api_key=self._api_key)
        except ImportError:
            raise ImportError("anthropic ���ッケージが必要です: pip install anthropic")

    def _init_cache_db(self) -> None:
        Path(self._cache_db_path).parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(self._cache_db_path) as conn:
            conn.executescript(_CACHE_SCHEMA)

    def get_cached(self, module: str, input_data: Any) -> Optional[dict]:
        """キャッシュからの結果取得。"""
        key = self._cache_key(module, input_data)
        with sqlite3.connect(self._cache_db_path) as conn:
            row = conn.execute(
                "SELECT result_json FROM claude_cache WHERE cache_key = ?", (key,)
            ).fetchone()
        if row:
            return json.loads(row[0])
        return None

    def set_cached(
        self, module: str, input_data: Any, result: dict, model: str = "",
        input_tokens: int = 0, output_tokens: int = 0
    ) -> None:
        """結果をキャッシュに保存。"""
        key = self._cache_key(module, input_data)
        with sqlite3.connect(self._cache_db_path) as conn:
            conn.execute(
                """INSERT OR REPLACE INTO claude_cache
                   (cache_key, module, result_json, model, input_tokens, output_tokens)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (key, module, json.dumps(result, ensure_ascii=False), model, input_tokens, output_tokens),
            )

    def send_messages(
        self, requests: list[BatchRequest], use_batch: bool = True,
        poll_timeout_minutes: int = 20,
    ) -> list[BatchResult]:
        """
        メッセージを送信。
        use_batch=True: Batch API（非同期、50%オフ）
        use_batch=False: 同期 Messages API（テスト・少量用）
        poll_timeout_minutes: Batch API ポーリングのタイムアウト（デフォルト20分）
        """
        if not requests:
            return []

        if self.is_credit_exhausted():
            logger.warning("クレジット不足フラグ検出: %d 件のリクエストをスキップ", len(requests))
            return []

        if use_batch and len(requests) >= 5:
            return self._send_batch(requests, poll_timeout_minutes=poll_timeout_minutes)
        else:
            return self._send_sync(requests)

    def _send_batch(
        self, requests: list[BatchRequest], poll_timeout_minutes: int = 20,
    ) -> list[BatchResult]:
        """Batch API で非同期送信 → ポーリング → 結果取得。"""
        batch_requests = []
        for req in requests:
            params: dict[str, Any] = {
                "model": req.model,
                "max_tokens": req.max_tokens,
                "temperature": req.temperature,
                "messages": req.messages,
            }
            if req.system:
                params["system"] = [
                    {"type": "text", "text": req.system, "cache_control": {"type": "ephemeral"}}
                ]
            batch_requests.append({
                "custom_id": req.custom_id,
                "params": params,
            })

        logger.info("Batch API 送信: %d リクエスト", len(batch_requests))

        try:
            batch = self._client.messages.batches.create(requests=batch_requests)
        except Exception as e:
            if _is_credit_error(e):
                self.mark_credit_exhausted()
                raise CreditError(str(e)) from e
            logger.warning("Batch API 作成失敗 → 同期 API フォールバック (%d件): %s", len(requests), e)
            return self._send_sync(requests)

        batch_id = batch.id
        logger.info("Batch ID: %s, status: %s", batch_id, batch.processing_status)

        results = self._poll_batch(batch_id, timeout_minutes=poll_timeout_minutes)
        succeeded = sum(1 for r in results if not r.error)
        if not succeeded:
            logger.warning("Batch 結果なし → 同期 API フォールバック (%d件)", len(requests))
            results = self._send_sync(requests)
        return results

    def _poll_batch(self, batch_id: str, timeout_minutes: int = 20) -> list[BatchResult]:
        """バッチの完了をポーリング。タイムアウト時は部分結果を返す。"""
        deadline = time.time() + timeout_minutes * 60
        poll_interval = 10

        while time.time() < deadline:
            try:
                batch = self._client.messages.batches.retrieve(batch_id)
            except Exception as e:
                logger.warning("Batch ポーリング失敗: %s（リトライ）", e)
                time.sleep(poll_interval)
                continue

            status = batch.processing_status
            if status == "ended":
                logger.info("Batch 完了: %s", batch_id)
                return self._retrieve_batch_results(batch_id)
            elif status in ("canceling", "canceled", "expired"):
                logger.warning("Batch 異常終了: %s (status=%s) — 部分結果を取得", batch_id, status)
                return self._retrieve_batch_results(batch_id)

            counts = batch.request_counts
            logger.info(
                "Batch 処理中: succeeded=%d, errored=%d, processing=%d",
                counts.succeeded, counts.errored, counts.processing,
            )
            time.sleep(poll_interval)
            poll_interval = min(poll_interval * 1.5, 30)

        logger.warning("Batch タイムアウト (%d分): %s — 部分結果を取得してキャンセル", timeout_minutes, batch_id)
        partial = self._retrieve_batch_results(batch_id)
        try:
            self._client.messages.batches.cancel(batch_id)
            logger.info("Batch キャンセル送信: %s", batch_id)
        except Exception as e:
            logger.warning("Batch キャンセル失敗: %s", e)
        if partial:
            succeeded = sum(1 for r in partial if not r.error)
            logger.info("部分結果: %d/%d 件取得", succeeded, len(partial))
        return partial

    def _retrieve_batch_results(self, batch_id: str) -> list[BatchResult]:
        """バ��チ結果を取得。"""
        results = []
        try:
            for result in self._client.messages.batches.results(batch_id):
                custom_id = result.custom_id
                if result.result.type == "succeeded":
                    msg = result.result.message
                    content = ""
                    for block in msg.content:
                        if block.type == "text":
                            content += block.text
                    results.append(BatchResult(
                        custom_id=custom_id,
                        content=content,
                        input_tokens=msg.usage.input_tokens,
                        output_tokens=msg.usage.output_tokens,
                    ))
                else:
                    error_msg = str(getattr(result.result, "error", "unknown error"))
                    results.append(BatchResult(custom_id=custom_id, error=error_msg))
        except Exception as e:
            logger.error("Batch 結果取得失敗: %s", e)

        return results

    def _send_sync(self, requests: list[BatchRequest]) -> list[BatchResult]:
        """同期 Messages API で送信（少量・テスト用）。"""
        results = []
        for req in requests:
            for attempt in range(3):
                try:
                    params: dict[str, Any] = {
                        "model": req.model,
                        "max_tokens": req.max_tokens,
                        "temperature": req.temperature,
                        "messages": req.messages,
                    }
                    if req.system:
                        params["system"] = [
                            {"type": "text", "text": req.system, "cache_control": {"type": "ephemeral"}}
                        ]
                    msg = self._client.messages.create(**params)
                    content = ""
                    for block in msg.content:
                        if block.type == "text":
                            content += block.text
                    results.append(BatchResult(
                        custom_id=req.custom_id,
                        content=content,
                        input_tokens=msg.usage.input_tokens,
                        output_tokens=msg.usage.output_tokens,
                    ))
                    break
                except Exception as e:
                    if _is_credit_error(e):
                        self.mark_credit_exhausted()
                        logger.warning("クレジット不足（同期API）: %d件処理済み、残り中断", len(results))
                        return results
                    if attempt < 2:
                        wait = 2 ** (attempt + 1)
                        logger.warning("API エラー（リトライ %d/%d, %ds待機）: %s", attempt + 1, 3, wait, e)
                        time.sleep(wait)
                    else:
                        logger.error("API エラー（最終）: %s", e)
                        results.append(BatchResult(custom_id=req.custom_id, error=str(e)))
        return results

    def parse_json_response(self, content: str) -> Optional[dict]:
        """レスポンスから JSON を抽出。```json ブロックにも対応。"""
        content = content.strip()
        if content.startswith("```"):
            lines = content.split("\n")
            json_lines = []
            inside = False
            for line in lines:
                if line.startswith("```") and not inside:
                    inside = True
                    continue
                elif line.startswith("```") and inside:
                    break
                elif inside:
                    json_lines.append(line)
            content = "\n".join(json_lines)

        try:
            return json.loads(content)
        except json.JSONDecodeError:
            start = content.find("{")
            end = content.rfind("}") + 1
            if start >= 0 and end > start:
                try:
                    return json.loads(content[start:end])
                except json.JSONDecodeError:
                    pass
            logger.warning("JSON パース失��: %.200s", content)
            return None

    @staticmethod
    def _cache_key(module: str, input_data: Any) -> str:
        data_str = json.dumps(input_data, sort_keys=True, ensure_ascii=False)
        h = hashlib.sha256(data_str.encode()).hexdigest()[:16]
        return f"{module}:{h}"

    @staticmethod
    def mark_credit_exhausted() -> None:
        """クレジット不足フラグを作成。以降の全 Claude API 呼び出しをスキップさせる。"""
        _CREDIT_EXHAUSTED_FLAG.parent.mkdir(parents=True, exist_ok=True)
        _CREDIT_EXHAUSTED_FLAG.touch()
        logger.warning("クレジット不足フラグを作成: %s", _CREDIT_EXHAUSTED_FLAG)

    @staticmethod
    def is_credit_exhausted() -> bool:
        """クレジット不足フラグの存在チェック。24時間経過で自動リセット。"""
        if not _CREDIT_EXHAUSTED_FLAG.exists():
            return False
        age = time.time() - _CREDIT_EXHAUSTED_FLAG.stat().st_mtime
        if age > 86400:
            _CREDIT_EXHAUSTED_FLAG.unlink(missing_ok=True)
            logger.info("クレジットフラグ TTL 切れ（24h）: 自動削除")
            return False
        return True

    @staticmethod
    def clear_credit_flag() -> None:
        """クレジット不足フラグを削除。"""
        if _CREDIT_EXHAUSTED_FLAG.exists():
            _CREDIT_EXHAUSTED_FLAG.unlink()
            logger.info("クレジット不足フラグを削除")

    @staticmethod
    def is_available() -> bool:
        """API キーが設定されているか確認。"""
        return bool(os.environ.get("ANTHROPIC_API_KEY"))
