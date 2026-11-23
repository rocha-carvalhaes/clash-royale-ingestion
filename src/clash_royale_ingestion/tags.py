from urllib.parse import quote


def normalize_tag(tag: str) -> str:
    """Retorna a tag em maiúsculas, sempre com '#' no início."""
    t = tag.strip().upper()
    if not t:
        raise ValueError("tag vazia")
    return t if t.startswith("#") else f"#{t}"


def encode_tag(tag: str) -> str:
    """Tag pronta para a URL: '#ABC' -> '%23ABC'."""
    return quote(normalize_tag(tag), safe="")


def tag_for_path(tag: str) -> str:
    """Tag sem '#', usada na partição do GCS."""
    return normalize_tag(tag).lstrip("#")
