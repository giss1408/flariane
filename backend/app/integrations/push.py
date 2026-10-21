"""Firebase Cloud Messaging (HTTP v1) for admin devices.

Notification text never contains customer names, phone numbers or amounts — only the order reference.
"""

import json
import logging
from typing import Any

import httpx

from app.config import get_settings

log = logging.getLogger("flariane.push")
SENT_LOG: list[dict[str, Any]] = []


class PushError(Exception):
    pass


def _access_token() -> str:
    from google.auth.transport.requests import Request
    from google.oauth2 import service_account

    info = json.loads(get_settings().fcm_service_account_json)
    creds = service_account.Credentials.from_service_account_info(
        info, scopes=["https://www.googleapis.com/auth/firebase.messaging"]
    )
    creds.refresh(Request())
    return creds.token


async def send_push(token: str, title: str, body: str, data: dict[str, str]) -> str:
    s = get_settings()
    if s.push_mode == "log":
        SENT_LOG.append({"token": token, "title": title, "body": body, "data": data})
        log.info("push(log) %s %s", title, data)
        return f"push.log.{len(SENT_LOG)}"
    message = {"message": {"token": token, "notification": {"title": title, "body": body}, "data": data}}
    url = f"https://fcm.googleapis.com/v1/projects/{s.fcm_project_id}/messages:send"
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.post(url, json=message, headers={"Authorization": f"Bearer {_access_token()}"})
    if resp.status_code >= 400:
        raise PushError(f"{resp.status_code}: {resp.text[:200]}")
    return resp.json().get("name", "")
