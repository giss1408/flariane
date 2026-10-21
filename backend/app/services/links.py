"""SHEIN share links. The server never fetches them: OneLink pages redirect with JavaScript,
and fetching user-supplied URLs would open SSRF risk. Validate, store as shared, let the admin open them."""

import re
from urllib.parse import urlsplit

URL_RE = re.compile(r"https?://[^\s<>\"']+")
SHEIN_SHARE = re.compile(r"^https://onelink\.shein\.com/\d+/[A-Za-z0-9]+(\?[\w=&%.-]*)?$", re.ASCII)
MAX_URL_LENGTH = 1000


def extract_shein_urls(text: str) -> list[str]:
    urls: list[str] = []
    for raw in URL_RE.findall(text or ""):
        raw = raw.rstrip(".,;:!?)")  # punctuation glued to the end of shared text
        if len(raw) > MAX_URL_LENGTH:
            continue
        try:
            u = urlsplit(raw)
            port = u.port  # raises ValueError on a malformed port
        except ValueError:
            continue
        if u.scheme != "https" or u.username or u.password or port:
            continue
        host = (u.hostname or "").lower()
        if host == "onelink.shein.com":
            if SHEIN_SHARE.match(raw):
                urls.append(raw)
        elif host == "shein.com" or host.endswith(".shein.com"):
            urls.append(raw)
    return list(dict.fromkeys(urls))  # dedupe, keep order


def log_safe(url: str | None) -> str:
    """Share links grant access to a cart: log only host + last 4 chars."""
    if not url:
        return "-"
    host = urlsplit(url).hostname or "?"
    return f"{host}/…{url[-4:]}"


_PRODUCT_ID = re.compile(r"-p-(\d+)")


def product_id_from_url(url: str | None) -> str | None:
    if not url:
        return None
    m = _PRODUCT_ID.search(url)
    return m.group(1) if m else None
