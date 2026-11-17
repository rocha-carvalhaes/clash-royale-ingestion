from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    api_token: str
    neon_dsn: str
    gcs_bucket: str
    api_base: str = "https://api.clashroyale.com/v1"
    request_interval_s: float = 0.2
    max_retries: int = 4
    timeout_s: float = 20.0

    @classmethod
    def from_env(cls) -> "Config":
        def req(name: str) -> str:
            v = os.environ.get(name)
            if not v:
                raise RuntimeError(f"variável de ambiente ausente: {name}")
            return v

        return cls(
            api_token=req("CR_API_TOKEN"),
            neon_dsn=req("NEON_DSN"),
            gcs_bucket=req("GCS_BUCKET"),
            api_base=os.environ.get("CR_API_BASE", cls.api_base),
            request_interval_s=float(os.environ.get("CR_REQUEST_INTERVAL_S", cls.request_interval_s)),
            max_retries=int(os.environ.get("CR_MAX_RETRIES", cls.max_retries)),
            timeout_s=float(os.environ.get("CR_TIMEOUT_S", cls.timeout_s)),
        )
