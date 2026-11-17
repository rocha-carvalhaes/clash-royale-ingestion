from __future__ import annotations


class FatalRunError(Exception):
    """Erro que deve abortar a execução inteira (ex.: 403 = IP não autorizado)."""


def classify_status(status_code: int | None) -> str | None:
    """Mapeia o status HTTP para error_class. None = sucesso."""
    if status_code is None:
        return "timeout"
    if status_code == 200:
        return None
    if status_code == 403:
        return "forbidden"
    if status_code == 404:
        return "not_found"
    if status_code == 429:
        return "rate_limited"
    if 500 <= status_code < 600:
        return "server_error"
    return f"http_{status_code}"


def is_retryable(error_class: str | None) -> bool:
    return error_class in {"timeout", "rate_limited", "server_error"}
