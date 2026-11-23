from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID

from .tags import tag_for_path

PREFIX = "bronze/clash_royale"


def battlelog_object_name(tag: str, fetch_id: UUID, ts: datetime) -> str:
    """bronze/clash_royale/battlelog/dt=YYYY-MM-DD/hr=HH/tag=<TAG>/<fetch_id>.json.gz"""
    ts = ts.astimezone(timezone.utc)
    return (
        f"{PREFIX}/battlelog/dt={ts:%Y-%m-%d}/hr={ts:%H}/"
        f"tag={tag_for_path(tag)}/{fetch_id}.json.gz"
    )
