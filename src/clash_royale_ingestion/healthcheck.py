"""Pings para o Healthchecks.io (https://healthchecks.io/docs/http_api/).

O alerta de "não rodou" depende do serviço externo: ele espera um ping por dia e avisa se não chegar.
Falhas de rede aqui nunca derrubam a ingestão.
"""
from __future__ import annotations

import logging
import uuid

import httpx

log = logging.getLogger("clash_royale_ingestion")


class Healthcheck:
    def __init__(self, ping_url: str | None, client: httpx.Client | None = None):
        self._url = ping_url.rstrip("/") if ping_url else None
        self._http = client or httpx.Client(timeout=10)
        self._rid = str(uuid.uuid4())  # liga o ping de início ao de fim (mede a duração)

    def start(self) -> None:
        self._ping("/start", None)

    def finish(self, exit_code: int, summary: str) -> None:
        # /0 = sucesso; qualquer outro código é marcado como falha e dispara o alerta
        self._ping(f"/{exit_code}", summary)

    def _ping(self, suffix: str, body: str | None) -> None:
        if not self._url:
            return
        try:
            self._http.post(f"{self._url}{suffix}", params={"rid": self._rid},
                            content=(body or "").encode()[:10_000])
        except httpx.HTTPError as exc:
            log.warning("healthcheck ping falhou: %s", exc)
