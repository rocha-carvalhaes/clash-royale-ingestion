from datetime import datetime, timezone
from uuid import UUID

import pytest

from clash_royale_ingestion.errors import classify_status, is_retryable
from clash_royale_ingestion.paths import battlelog_object_name
from clash_royale_ingestion.repo import latest_battle_time
from clash_royale_ingestion.tags import encode_tag, normalize_tag, tag_for_path


def test_encode_tag():
    assert encode_tag("#abc123") == "%23ABC123"
    assert encode_tag("ABC123") == "%23ABC123"


def test_normalize_and_path_tag():
    assert normalize_tag(" #p0y ") == "#P0Y"
    assert tag_for_path("#P0Y") == "P0Y"


def test_empty_tag():
    with pytest.raises(ValueError):
        normalize_tag("  ")


@pytest.mark.parametrize("code,expected", [
    (200, None), (403, "forbidden"), (404, "not_found"), (429, "rate_limited"),
    (500, "server_error"), (503, "server_error"), (None, "timeout"), (400, "http_400"),
])
def test_classify_status(code, expected):
    assert classify_status(code) == expected


def test_retryable():
    assert is_retryable("rate_limited") and is_retryable("server_error") and is_retryable("timeout")
    assert not is_retryable("forbidden") and not is_retryable("not_found") and not is_retryable(None)


def test_object_name():
    fid = UUID("12345678-1234-5678-1234-567812345678")
    ts = datetime(2026, 11, 17, 9, 30, tzinfo=timezone.utc)
    assert battlelog_object_name("#ABC", fid, ts) == (
        "bronze/clash_royale/battlelog/dt=2026-11-17/hr=09/tag=ABC/"
        "12345678-1234-5678-1234-567812345678.json.gz"
    )


def test_latest_battle_time():
    body = b'[{"battleTime":"20260101T120000.000Z"},{"battleTime":"20260102T080000.000Z"}]'
    assert latest_battle_time(body) == datetime(2026, 1, 2, 8, 0, tzinfo=timezone.utc)
    assert latest_battle_time(b"[]") is None
    assert latest_battle_time(b"nao e json") is None
