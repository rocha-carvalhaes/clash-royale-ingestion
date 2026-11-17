from __future__ import annotations

import json
import logging
import sys
import uuid
from datetime import datetime, timezone

from .api import ClashRoyaleClient
from .config import Config
from .paths import battlelog_object_name
from .repo import Repo, latest_battle_time
from .storage import BronzeWriter

log = logging.getLogger("cr_ingest")


def _log(event: str, **fields) -> None:
    log.info(json.dumps({"event": event, "ts": datetime.now(timezone.utc).isoformat(), **fields}))


def run(cfg: Config) -> int:
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    repo = Repo(cfg.neon_dsn)
    writer = BronzeWriter(cfg.gcs_bucket)
    api = ClashRoyaleClient(cfg.api_token, cfg.api_base, cfg.request_interval_s,
                            cfg.max_retries, cfg.timeout_s)
    tags = repo.active_tags()
    _log("run_start", run_id=run_id, tags=len(tags))
    ok = failed = 0
    try:
        for tag in tags:
            fetch_id = uuid.uuid4()
            requested_at = datetime.now(timezone.utc)
            res = api.battlelog(tag)
            gcs_uri = None
            if res.body is not None:
                name = battlelog_object_name(tag, fetch_id, requested_at)
                gcs_uri = writer.write(name, res.body)
            repo.log_fetch(fetch_id=fetch_id, endpoint="battlelog", subject_tag=tag,
                           run_id=run_id, requested_at=requested_at,
                           status_code=res.status_code, error_class=res.error_class,
                           latency_ms=res.latency_ms,
                           bytes_=len(res.body) if res.body else None, gcs_uri=gcs_uri)
            if res.error_class is None:
                repo.mark_fetched(tag, requested_at, latest_battle_time(res.body))
                ok += 1
            else:
                failed += 1
                _log("fetch_failed", tag=tag, status=res.status_code, error=res.error_class)
                if res.error_class == "forbidden":
                    _log("fatal", reason="403: IP de saída não está cadastrado na chave da API")
                    return 2
    finally:
        repo.close()
    _log("run_end", run_id=run_id, ok=ok, failed=failed)
    return 1 if failed else 0


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)
    sys.exit(run(Config.from_env()))


if __name__ == "__main__":
    main()
