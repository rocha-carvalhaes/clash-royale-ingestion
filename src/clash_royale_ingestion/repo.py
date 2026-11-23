from __future__ import annotations

import json
from datetime import datetime, timezone
from uuid import UUID

import psycopg


class Repo:
    def __init__(self, dsn: str):
        self._conn = psycopg.connect(dsn, autocommit=True)

    def active_tags(self) -> list[str]:
        rows = self._conn.execute(
            "SELECT player_tag FROM players_watchlist WHERE is_active ORDER BY player_tag"
        ).fetchall()
        return [r[0] for r in rows]

    def log_fetch(self, *, fetch_id: UUID, endpoint: str, subject_tag: str | None, run_id: str,
                  requested_at: datetime, status_code: int | None, error_class: str | None,
                  latency_ms: int, bytes_: int | None, gcs_uri: str | None) -> None:
        self._conn.execute(
            """INSERT INTO fetch_log (fetch_id, endpoint, subject_tag, run_id, requested_at,
                   status_code, error_class, latency_ms, bytes, gcs_uri)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
            (fetch_id, endpoint, subject_tag, run_id, requested_at, status_code,
             error_class, latency_ms, bytes_, gcs_uri),
        )

    def mark_fetched(self, tag: str, fetched_at: datetime, last_battle_at: datetime | None) -> None:
        self._conn.execute(
            """UPDATE players_watchlist
               SET last_fetched_at = %s,
                   last_battle_at = GREATEST(last_battle_at, %s)
               WHERE player_tag = %s""",
            (fetched_at, last_battle_at, tag),
        )

    def start_run(self, run_id: str, host: str) -> None:
        self._conn.execute(
            "INSERT INTO run_log (run_id, started_at, status, host) VALUES (%s, now(), 'running', %s)",
            (run_id, host),
        )

    def update_run_total(self, run_id: str, tags_total: int) -> None:
        self._conn.execute("UPDATE run_log SET tags_total = %s WHERE run_id = %s", (tags_total, run_id))

    def finish_run(self, run_id: str, status: str, tags_ok: int, tags_failed: int,
                   bytes_total: int, error_message: str | None) -> None:
        self._conn.execute(
            """UPDATE run_log
               SET finished_at = now(), status = %s, tags_ok = %s, tags_failed = %s,
                   bytes_total = %s, error_message = %s
               WHERE run_id = %s""",
            (status, tags_ok, tags_failed, bytes_total, error_message, run_id),
        )

    def close(self) -> None:
        self._conn.close()


def latest_battle_time(body: bytes) -> datetime | None:
    """Maior battleTime do corpo (formato 20240101T120000.000Z). Só leitura, não altera o bruto."""
    try:
        battles = json.loads(body)
        times = [b["battleTime"] for b in battles if "battleTime" in b]
        if not times:
            return None
        return datetime.strptime(max(times), "%Y%m%dT%H%M%S.%fZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError, KeyError):
        return None
