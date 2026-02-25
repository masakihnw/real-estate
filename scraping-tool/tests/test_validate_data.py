"""validate_data.py のユニットテスト"""
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

import pytest

from validate_data import ValidationResult, validate_listings


class TestValidationResult:
    def test_empty_listings_is_error(self):
        """空のリストはエラーになること"""
        result = validate_listings([])
        assert result.has_errors
        assert "空" in result.errors[0]

    def test_valid_listings_pass(self):
        """必須フィールドを持つ物件はエラーなし"""
        listings = [
            {
                "url": "https://example.com/1",
                "name": "テスト物件",
                "price_man": 5000,
                "address": "東京都渋谷区",
            },
            {
                "url": "https://example.com/2",
                "name": "テスト物件2",
                "price_man": 6000,
                "address": "東京都港区",
            },
        ]
        result = validate_listings(listings)
        assert not result.has_errors

    def test_missing_url_is_warning(self):
        """URLが欠損している場合は警告"""
        listings = [
            {"url": "", "name": "テスト", "price_man": 5000, "address": "東京都渋谷区"},
            {
                "url": "https://example.com/2",
                "name": "テスト2",
                "price_man": 6000,
                "address": "東京都港区",
            },
        ]
        result = validate_listings(listings)
        assert len(result.warnings) > 0 or len(result.errors) > 0

    def test_price_anomaly_detection(self):
        """価格が異常値の場合に検出されること"""
        listings = [
            {
                "url": "https://example.com/1",
                "name": "テスト",
                "price_man": -100,
                "address": "東京都",
            },
            {
                "url": "https://example.com/2",
                "name": "テスト2",
                "price_man": 5000,
                "address": "東京都",
            },
        ]
        result = validate_listings(listings)
        assert len(result.warnings) > 0 or len(result.errors) > 0

    def test_duplicate_url_detection(self):
        """重複URLの検出"""
        listings = [
            {
                "url": "https://example.com/1",
                "name": "テスト",
                "price_man": 5000,
                "address": "東京都",
            },
            {
                "url": "https://example.com/1",
                "name": "テスト重複",
                "price_man": 6000,
                "address": "東京都",
            },
        ]
        result = validate_listings(listings)
        assert len(result.warnings) > 0 or len(result.errors) > 0
