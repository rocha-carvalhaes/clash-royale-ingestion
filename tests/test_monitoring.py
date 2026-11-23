import httpx

from clash_royale_ingestion.api import ClashRoyaleClient
from clash_royale_ingestion.errors import is_retryable
from clash_royale_ingestion.healthcheck import Healthcheck
from clash_royale_ingestion.main import RunStats, run_status


def _client(handler):
    return ClashRoyaleClient("t", "https://x", interval_s=0, max_retries=2, timeout_s=1,
                             client=httpx.Client(transport=httpx.MockTransport(handler)),
                             sleep=lambda s: None)


def test_connect_error_is_network_error_and_retried():
    calls = []

    def handler(request):
        calls.append(request)
        raise httpx.ConnectError("recusada", request=request)

    res = _client(handler).battlelog("#ABC")
    assert res.error_class == "network_error" and res.body is None
    assert len(calls) == 3  # 1 tentativa + 2 retentativas
    assert is_retryable("network_error")


def test_retry_recovers_after_server_error():
    responses = iter([httpx.Response(503), httpx.Response(200, content=b"[]")])
    res = _client(lambda r: next(responses)).battlelog("#ABC")
    assert res.error_class is None and res.body == b"[]"


def test_run_status():
    assert run_status(RunStats(3, 3, 0), fatal=False) == ("success", 0)
    assert run_status(RunStats(3, 2, 1), fatal=False) == ("partial", 1)
    assert run_status(RunStats(3, 0, 1), fatal=True) == ("fatal", 2)


def test_healthcheck_pings_start_and_exit_code():
    seen = []

    def handler(request):
        seen.append((request.url.path, request.url.params["rid"], request.content))
        return httpx.Response(200)

    hc = Healthcheck("https://hc-ping.com/abc/", client=httpx.Client(transport=httpx.MockTransport(handler)))
    hc.start()
    hc.finish(1, "parcial")
    assert [p for p, _, _ in seen] == ["/abc/start", "/abc/1"]
    assert seen[0][1] == seen[1][1]  # mesmo rid liga início e fim
    assert seen[1][2] == b"parcial"


def test_healthcheck_never_raises():
    def handler(request):
        raise httpx.ConnectError("fora do ar", request=request)

    hc = Healthcheck("https://hc-ping.com/abc", client=httpx.Client(transport=httpx.MockTransport(handler)))
    hc.start()
    hc.finish(0, "")


def test_healthcheck_disabled_without_url():
    def handler(request):
        raise AssertionError("não deveria pingar")

    Healthcheck(None, client=httpx.Client(transport=httpx.MockTransport(handler))).finish(2, "x")
