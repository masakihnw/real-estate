import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from investment_enricher import _extract_commute_minutes


def test_extract_commute_minutes_prefers_v2():
    listing = {
        "commute_info_v2": json.dumps(
            {
                "offices": {
                    "playground": {"representative_minutes": 42},
                    "m3career": {"representative_minutes": 36},
                }
            },
            ensure_ascii=False,
        ),
        "commute_info": json.dumps(
            {
                "playground": {"minutes": 99},
                "m3career": {"minutes": 88},
            },
            ensure_ascii=False,
        ),
    }

    assert _extract_commute_minutes(listing) == [42, 36]


def test_extract_commute_minutes_falls_back_to_legacy():
    listing = {
        "commute_info": json.dumps(
            {
                "playground": {"minutes": 51},
                "m3career": {"minutes": 44},
            },
            ensure_ascii=False,
        )
    }

    assert _extract_commute_minutes(listing) == [51, 44]
