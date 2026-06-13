"""claude_image_analyzer の純ロジック特性テスト（refactor P8）。

Claude API を叩く analyze_listing_images は対象外。サムネイル選定
（_apply_best_thumbnails）とカテゴリ構造化（_build_image_categories）の
純ロジックを固定する。
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from claude_image_analyzer import (  # noqa: E402
    _apply_best_thumbnails,
    _build_image_categories,
)


# ─────────────────────── _apply_best_thumbnails ───────────────────────


def test_best_thumbnail_picks_highest_score():
    listing = {
        "suumo_images": [
            {"url": "a", "claude_thumbnail_score": 0.3},
            {"url": "b", "claude_thumbnail_score": 0.9},
            {"url": "c", "claude_thumbnail_score": 0.5},
        ]
    }
    _apply_best_thumbnails([listing])
    assert listing["best_thumbnail_url"] == "b"


def test_best_thumbnail_excludes_junk():
    listing = {
        "suumo_images": [
            {"url": "junk", "claude_thumbnail_score": 0.99, "is_junk": True},
            {"url": "ok", "claude_thumbnail_score": 0.4},
        ]
    }
    _apply_best_thumbnails([listing])
    assert listing["best_thumbnail_url"] == "ok"


def test_best_thumbnail_no_valid_images_sets_nothing():
    listing = {"suumo_images": [{"url": "junk", "is_junk": True}]}
    _apply_best_thumbnails([listing])
    assert "best_thumbnail_url" not in listing


def test_best_thumbnail_zero_score_sets_nothing():
    listing = {"suumo_images": [{"url": "a", "claude_thumbnail_score": 0.0}]}
    _apply_best_thumbnails([listing])
    assert "best_thumbnail_url" not in listing


def test_best_thumbnail_empty_images_noop():
    listing = {"suumo_images": []}
    _apply_best_thumbnails([listing])
    assert "best_thumbnail_url" not in listing


# ─────────────────────── _build_image_categories ───────────────────────


def test_categories_grouped_and_sorted_by_quality():
    listing = {
        "suumo_images": [
            {"url": "lr1", "claude_category": "living", "claude_quality": 0.5},
            {"url": "lr2", "claude_category": "living", "claude_quality": 0.9},
            {"url": "kt1", "claude_category": "kitchen", "claude_quality": 0.7},
        ]
    }
    _build_image_categories([listing])
    cats = listing["image_categories"]
    assert set(cats.keys()) == {"living", "kitchen"}
    # 品質降順
    assert [img["url"] for img in cats["living"]] == ["lr2", "lr1"]
    assert [img["url"] for img in cats["kitchen"]] == ["kt1"]


def test_categories_excludes_junk():
    listing = {
        "suumo_images": [
            {"url": "ok", "claude_category": "living", "claude_quality": 0.5},
            {"url": "junk", "claude_category": "living", "is_junk": True},
        ]
    }
    _build_image_categories([listing])
    assert [img["url"] for img in listing["image_categories"]["living"]] == ["ok"]


def test_categories_default_category_other():
    listing = {"suumo_images": [{"url": "x", "claude_quality": 0.5}]}
    _build_image_categories([listing])
    assert "other" in listing["image_categories"]


def test_categories_all_junk_sets_nothing():
    listing = {"suumo_images": [{"url": "j", "claude_category": "living", "is_junk": True}]}
    _build_image_categories([listing])
    assert "image_categories" not in listing


def test_categories_empty_images_noop():
    listing = {"suumo_images": []}
    _build_image_categories([listing])
    assert "image_categories" not in listing
