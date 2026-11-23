from __future__ import annotations

import time
from dataclasses import dataclass

import httpx

from .errors import classify_status, is_retryable
from .tags import encode_tag


@dataclass
class FetchResult:
    status_code: int | None
    error_class: str | None
    latency_ms: int
    body: bytes | None  # corpo bruto, só quando 200


class ClashRoyaleClient:
    def __init__(self, token: str, base_url: str, interval_s: float, max_retries: int,
                 timeout_s: float, client: httpx.Client | None = None, sleep=time.sleep):
        self._base = base_url.rstrip("/")
        self._interval = interval_s
        self._max_retries = max_retries
        self._sleep = sleep
        self._last_call = 0.0
        self._http = client or httpx.Client(
            headers={"Authorization": f"Bearer {token}"}, timeout=timeout_s
        )

    def _throttle(self) -> None:
        wait = self._interval - (time.monotonic() - self._last_call)
        if wait > 0:
            self._sleep(wait)
        self._last_call = time.monotonic()

    def battlelog(self, tag: str) -> FetchResult:
        url = f"{self._base}/players/{encode_tag(tag)}/battlelog"
        result = self._once(url)
        for attempt in range(self._max_retries):
            if not is_retryable(result.error_class):
                break
            self._sleep(2 ** attempt)  # 1s, 2s, 4s, 8s
            result = self._once(url)
        return result

    def _once(self, url: str) -> FetchResult:
        self._throttle()
        start = time.monotonic()
        try:
            resp = self._http.get(url)
        except httpx.TimeoutException:
            return FetchResult(None, "timeout", int((time.monotonic() - start) * 1000), None)
        latency = int((time.monotonic() - start) * 1000)
        err = classify_status(resp.status_code)
        return FetchResult(resp.status_code, err, latency, resp.content if err is None else None)
