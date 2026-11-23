from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from uuid import UUID

import psycopg


class Repo:
    def __init__(self, dsn: str):
        self._conn = psycopg.connect(dsn, autocommit=True)

    def active_players(self) -> list[tuple[str, datetime | None]]:
        """(tag, last_battle_at) de cada jogador ativo."""
        return self._conn.execute(
            "SELECT player_tag, last_battle_at FROM players_watchlist WHERE is_active ORDER BY player_tag"
        ).fetchall()

    def log_fetch(self, *, fetch_id: UUID, endpoint: str, subject_tag: str | None, run_id: str,
                  requested_at: datetime, status_code: int | None, error_class: str | None,
                  latency_ms: int, bytes_: int | None, gcs_uri: str | None,
                  battles_count: int | None = None, new_battles_count: int | None = None) -> None:
        self._conn.execute(
            """INSERT INTO fetch_log (fetch_id, endpoint, subject_tag, run_id, requested_at,
                   status_code, error_class, latency_ms, bytes, gcs_uri,
                   battles_count, new_battles_count)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
            (fetch_id, endpoint, subject_tag, run_id, requested_at, status_code,
             error_class, latency_ms, bytes_, gcs_uri, battles_count, new_battles_count),
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

    def finish_run(self, run_id: str, status: str, stats, error_message: str | None) -> None:
        """stats: RunStats (main.py)."""
        self._conn.execute(
            """UPDATE run_log
               SET finished_at = now(), status = %s, tags_ok = %s, tags_failed = %s,
                   bytes_total = %s, battles_total = %s, new_battles_total = %s,
                   error_message = %s
               WHERE run_id = %s""",
            (status, stats.tags_ok, stats.tags_failed, stats.bytes_total,
             stats.battles_total, stats.new_battles_total, error_message, run_id),
        )

    def close(self) -> None:
        self._conn.close()


@dataclass(frozen=True)
class BattleStats:
    count: int
    new_count: int                 # batalhas mais recentes que o last_battle_at anterior
    latest: datetime | None


def battle_stats(body: bytes, since: datetime | None) -> BattleStats | None:
    """Conta batalhas do corpo (battleTime no formato 20240101T120000.000Z). Só leitura, não altera o bruto.

    None se o corpo não for uma lista de batalhas.
    """
    try:
        battles = json.loads(body)
        if not isinstance(battles, list):
            return None
        times = [datetime.strptime(b["battleTime"], "%Y%m%dT%H%M%S.%fZ").replace(tzinfo=timezone.utc)
                 for b in battles if isinstance(b, dict) and "battleTime" in b]
    except (ValueError, TypeError, KeyError):
        return None
    new = [t for t in times if since is None or t > since]
    return BattleStats(len(battles), len(new), max(times) if times else None)
