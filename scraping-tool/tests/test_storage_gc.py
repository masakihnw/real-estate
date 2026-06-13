"""image_storage / storage_gc（画像ストレージ GC・R2 対応）のテスト。"""

from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import image_storage
from storage_gc import (
    collect_image_urls,
    collect_refs,
    prune_manifest,
    scrub_enrichment_row,
    select_deletable,
)

SUPA_BASE = "https://dzhcumdmzskkvusynmyw.supabase.co/storage/v1/object/public/listing-images"
R2_BASE = "https://pub-test1234.r2.dev"


@pytest.fixture
def r2_env(monkeypatch):
    monkeypatch.setattr(image_storage, "R2_PUBLIC_BASE_URL", R2_BASE)
    monkeypatch.setattr(image_storage, "R2_ENDPOINT_URL", "https://acc.r2.cloudflarestorage.com")
    monkeypatch.setattr(image_storage, "R2_ACCESS_KEY_ID", "key")
    monkeypatch.setattr(image_storage, "R2_SECRET_ACCESS_KEY", "secret")


class TestExtractObjectName:
    def test_supabase_url(self):
        url = f"{SUPA_BASE}/property_images/ab12cd34.jpg"
        assert image_storage.extract_object_name(url) == "property_images/ab12cd34.jpg"

    def test_supabase_url_with_query(self):
        url = f"{SUPA_BASE}/floor_plans/ab12.jpg?"
        assert image_storage.extract_object_name(url) == "floor_plans/ab12.jpg"

    def test_r2_dev_url(self):
        url = f"{R2_BASE}/property_images/ab12cd34.jpg"
        assert image_storage.extract_object_name(url) == "property_images/ab12cd34.jpg"

    def test_r2_custom_domain(self, r2_env, monkeypatch):
        monkeypatch.setattr(image_storage, "R2_PUBLIC_BASE_URL", "https://img.example.com")
        url = "https://img.example.com/floor_plans/xy.jpg"
        assert image_storage.extract_object_name(url) == "floor_plans/xy.jpg"

    def test_external_url_returns_none(self):
        assert image_storage.extract_object_name(
            "https://img01.suumo.com/jj/resizeImage?src=a.jpg") is None

    def test_empty_and_none_like(self):
        assert image_storage.extract_object_name("") is None
        assert image_storage.extract_object_name(f"{SUPA_BASE}/") is None


class TestIsStoredUrl:
    def test_supabase(self):
        assert image_storage.is_stored_url(f"{SUPA_BASE}/property_images/a.jpg")

    def test_r2_dev(self):
        assert image_storage.is_stored_url(f"{R2_BASE}/property_images/a.jpg")

    def test_r2_custom_domain(self, monkeypatch):
        monkeypatch.setattr(image_storage, "R2_PUBLIC_BASE_URL", "https://img.example.com")
        assert image_storage.is_stored_url("https://img.example.com/floor_plans/a.jpg")

    def test_external(self):
        assert not image_storage.is_stored_url("https://img01.suumo.com/a.jpg")
        assert not image_storage.is_stored_url("")

    def test_firebase_is_not_stored(self):
        assert not image_storage.is_stored_url(
            "https://firebasestorage.googleapis.com/v0/b/x/o/a.jpg")


class TestUploadFloorPlansIsAlreadyStored:
    def test_delegates_to_image_storage(self):
        from upload_floor_plans import _is_already_stored
        assert _is_already_stored(f"{SUPA_BASE}/property_images/a.jpg")
        assert _is_already_stored(f"{R2_BASE}/property_images/a.jpg")
        assert not _is_already_stored("https://img01.suumo.com/a.jpg")


def _row(listing_id, suumo=None, floor=None, thumb=None, cats=None):
    return {
        "listing_id": listing_id,
        "suumo_images": suumo,
        "image_categories": cats,
        "floor_plan_images": floor,
        "best_thumbnail_url": thumb,
    }


class TestCollectRefs:
    def test_collect_image_urls_handles_malformed(self):
        row = _row(
            1,
            suumo=[{"url": "https://a/1.jpg", "label": "x"}, {"label": "no-url"}, "junk"],
            floor=["https://a/2.jpg", None, 5],
            thumb="https://a/3.jpg",
        )
        assert collect_image_urls(row) == [
            "https://a/1.jpg", "https://a/2.jpg", "https://a/3.jpg"]

    def test_collects_image_categories_urls(self):
        # 詳細画面が使う image_categories も参照に数える（GC 誤削除の回帰防止）
        row = _row(
            1,
            suumo=[{"url": f"{SUPA_BASE}/property_images/a.jpg"}],
            cats=[{"url": f"{SUPA_BASE}/property_images/b.jpg", "category": "view"}],
        )
        assert collect_image_urls(row) == [
            f"{SUPA_BASE}/property_images/a.jpg",
            f"{SUPA_BASE}/property_images/b.jpg",
        ]

    def test_image_categories_counted_as_refs(self):
        rows = [_row(1, cats=[{"url": f"{SUPA_BASE}/property_images/cat1.jpg"}])]
        active_refs, all_refs = collect_refs(rows, active_listing_ids={1})
        assert active_refs == {"property_images/cat1.jpg"}
        assert all_refs == {"property_images/cat1.jpg"}

    def test_active_vs_all_refs(self):
        rows = [
            _row(1, suumo=[{"url": f"{SUPA_BASE}/property_images/active1.jpg"}]),
            _row(2, floor=[f"{SUPA_BASE}/floor_plans/inactive1.jpg"]),
            _row(3, thumb="https://img01.suumo.com/external.jpg"),
        ]
        active_refs, all_refs = collect_refs(rows, active_listing_ids={1})
        assert active_refs == {"property_images/active1.jpg"}
        assert all_refs == {"property_images/active1.jpg", "floor_plans/inactive1.jpg"}

    def test_external_urls_ignored(self):
        rows = [_row(1, suumo=[{"url": "https://img01.suumo.com/a.jpg"}])]
        active_refs, all_refs = collect_refs(rows, {1})
        assert active_refs == set() and all_refs == set()


class TestSelectDeletable:
    def test_keeps_active_referenced(self):
        objects = {"property_images/a.jpg", "property_images/b.jpg", "floor_plans/c.jpg"}
        deletable = select_deletable(objects, active_refs={"property_images/a.jpg"})
        assert deletable == {"property_images/b.jpg", "floor_plans/c.jpg"}


class TestPruneManifest:
    def test_prunes_deleted_entries(self):
        manifest = {
            "https://orig/1.jpg": f"{SUPA_BASE}/property_images/keep.jpg",
            "https://orig/2.jpg": f"{SUPA_BASE}/property_images/gone.jpg",
        }
        pruned, count = prune_manifest(manifest, {"property_images/gone.jpg"})
        assert count == 1
        assert list(pruned) == ["https://orig/1.jpg"]

    def test_noop_when_nothing_deleted(self):
        manifest = {"https://orig/1.jpg": f"{SUPA_BASE}/property_images/keep.jpg"}
        pruned, count = prune_manifest(manifest, set())
        assert count == 0 and pruned == manifest


class TestScrubEnrichmentRow:
    def test_removes_deleted_refs_only(self):
        row = _row(
            1,
            suumo=[
                {"url": f"{SUPA_BASE}/property_images/gone.jpg", "label": "外観"},
                {"url": f"{SUPA_BASE}/property_images/keep.jpg", "label": "内装"},
                {"url": "https://img01.suumo.com/ext.jpg", "label": "外部"},
            ],
            floor=[f"{SUPA_BASE}/floor_plans/gone2.jpg"],
            thumb=f"{SUPA_BASE}/property_images/gone.jpg",
        )
        payload = scrub_enrichment_row(
            row, {"property_images/gone.jpg", "floor_plans/gone2.jpg"})
        assert payload == {
            "suumo_images": [
                {"url": f"{SUPA_BASE}/property_images/keep.jpg", "label": "内装"},
                {"url": "https://img01.suumo.com/ext.jpg", "label": "外部"},
            ],
            "floor_plan_images": [],
            "best_thumbnail_url": None,
        }

    def test_scrubs_image_categories(self):
        row = _row(
            1,
            cats=[
                {"url": f"{SUPA_BASE}/property_images/gone.jpg", "category": "view"},
                {"url": f"{SUPA_BASE}/property_images/keep.jpg", "category": "exterior"},
            ],
        )
        payload = scrub_enrichment_row(row, {"property_images/gone.jpg"})
        assert payload == {
            "image_categories": [
                {"url": f"{SUPA_BASE}/property_images/keep.jpg", "category": "exterior"},
            ],
        }

    def test_returns_none_when_unchanged(self):
        row = _row(1, suumo=[{"url": "https://img01.suumo.com/ext.jpg"}],
                   thumb=f"{SUPA_BASE}/property_images/keep.jpg")
        assert scrub_enrichment_row(row, {"property_images/gone.jpg"}) is None

    def test_handles_null_fields(self):
        assert scrub_enrichment_row(_row(1), {"property_images/gone.jpg"}) is None
