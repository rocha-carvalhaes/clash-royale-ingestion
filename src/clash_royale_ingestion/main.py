from __future__ import annotations

import json
import logging
import socket
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

from .api import ClashRoyaleClient
from .config import Config
from .healthcheck import Healthcheck
from .paths import battlelog_object_name
from .repo import Repo, latest_battle_time
from .storage import BronzeWriter

log = logging.getLogger("clash_royale_ingestion")

EXIT_SUCCESS, EXIT_PARTIAL, EXIT_FATAL = 0, 1, 2


def _log(event: str, **fields) -> None:
    log.info(json.dumps({"event": event, "ts": datetime.now(timezone.utc).isoformat(), **fields},
                        default=str))


@dataclass
class RunStats:
    tags_total: int = 0
    tags_ok: int = 0
    tags_failed: int = 0
    bytes_total: int = 0


def run_status(stats: RunStats, fatal: bool) -> tuple[str, int]:
    """Status gravado em run_log e exit code correspondente."""
    if fatal:
        return "fatal", EXIT_FATAL
    if stats.tags_failed:
        return "partial", EXIT_PARTIAL
    return "success", EXIT_SUCCESS


def _ingest(cfg: Config, repo: Repo, run_id: str, stats: RunStats) -> str | None:
    """Processa a watchlist. Retorna a mensagem de erro fatal, ou None."""
    writer = BronzeWriter(cfg.gcs_bucket)
    api = ClashRoyaleClient(cfg.api_token, cfg.api_base, cfg.request_interval_s,
                            cfg.max_retries, cfg.timeout_s)
    tags = repo.active_tags()
    stats.tags_total = len(tags)
    repo.update_run_total(run_id, stats.tags_total)
    _log("run_start", run_id=run_id, tags=stats.tags_total)

    for tag in tags:
        fetch_id = uuid.uuid4()
        requested_at = datetime.now(timezone.utc)
        res = api.battlelog(tag)
        error_class, gcs_uri = res.error_class, None
        if res.body is not None:
            try:
                gcs_uri = writer.write(battlelog_object_name(tag, fetch_id, requested_at), res.body)
            except Exception as exc:  # falha no GCS não pode apagar o registro da chamada
                error_class = "storage_error"
                _log("storage_failed", tag=tag, error=repr(exc))
        repo.log_fetch(fetch_id=fetch_id, endpoint="battlelog", subject_tag=tag,
                       run_id=run_id, requested_at=requested_at,
                       status_code=res.status_code, error_class=error_class,
                       latency_ms=res.latency_ms,
                       bytes_=len(res.body) if res.body else None, gcs_uri=gcs_uri)
        if error_class is None:
            repo.mark_fetched(tag, requested_at, latest_battle_time(res.body))
            stats.tags_ok += 1
            stats.bytes_total += len(res.body)
            continue
        stats.tags_failed += 1
        _log("fetch_failed", tag=tag, status=res.status_code, error=error_class)
        if error_class == "forbidden":
            return "403: IP de saída não está cadastrado na chave da API"
    return None


def run(cfg: Config) -> int:
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    stats = RunStats()
    health = Healthcheck(cfg.healthcheck_ping_url)
    health.start()
    repo: Repo | None = None
    status, exit_code, error_message = "crashed", EXIT_FATAL, None
    try:
        repo = Repo(cfg.neon_dsn)
        repo.start_run(run_id, socket.gethostname())
        error_message = _ingest(cfg, repo, run_id, stats)
        status, exit_code = run_status(stats, fatal=error_message is not None)
    except Exception as exc:  # qualquer erro inesperado vira 'crashed' no run_log e alerta
        error_message = f"{type(exc).__name__}: {exc}"
        log.exception("run_crashed")
    finally:
        if repo is not None:
            try:
                repo.finish_run(run_id, status, stats.tags_ok, stats.tags_failed,
                                stats.bytes_total, error_message)
            except Exception:
                log.exception("falha ao gravar run_log")
            repo.close()
        summary = (f"run_id={run_id} status={status} ok={stats.tags_ok} "
                   f"failed={stats.tags_failed}/{stats.tags_total}"
                   + (f"\n{error_message}" if error_message else ""))
        _log("run_end", run_id=run_id, status=status, ok=stats.tags_ok,
             failed=stats.tags_failed, error=error_message)
        health.finish(exit_code, summary)
    return exit_code


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)
    sys.exit(run(Config.from_env()))


if __name__ == "__main__":
    main()
