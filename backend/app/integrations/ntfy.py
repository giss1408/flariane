"""ntfy (https://ntfy.sh) for admin alerts: one HTTP POST, received by the ntfy app on the admin's phone.

Works alongside FCM and needs no Firebase project. Disabled while FLR_NTFY_TOPIC is empty.
Same rule as push: only the order reference, never customer names, phone numbers or amounts.
"""

import logging
from typing import Any

import httpx

from app.config import get_settings

log = logging.getLogger("flariane.ntfy")
SENT_LOG: list[dict[str, Any]] = []


async def send(title: str, body: str, *, priority: int = 3, tags: list[str] | None = None) -> None:
    s = get_settings()
    if not s.ntfy_topic:
        return
    # JSON publishing (not headers) so French accents arrive intact.
    message = {"topic": s.ntfy_topic, "title": title, "message": body, "priority": priority, "tags": tags or ["bell"]}
    if s.env == "test":
        SENT_LOG.append(message)
        return
    headers = {"Authorization": f"Bearer {s.ntfy_token}"} if s.ntfy_token else {}
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(s.ntfy_url.rstrip("/"), json=message, headers=headers)
    if resp.status_code >= 400:
        log.warning("ntfy failed: %s %s", resp.status_code, resp.text[:200])
