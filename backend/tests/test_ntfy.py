import pytest

from app import tasks
from app.config import get_settings
from app.integrations import ntfy


@pytest.fixture
def topic(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(get_settings(), "ntfy_topic", "flariane-test-topic")
    ntfy.SENT_LOG.clear()


async def test_disabled_without_topic() -> None:
    ntfy.SENT_LOG.clear()
    await tasks.push_admins("quote_requested", "FLR-ABC12", 1)
    assert ntfy.SENT_LOG == []


async def test_admin_event_goes_to_ntfy(topic: None) -> None:
    await tasks.push_admins("quote_requested", "FLR-ABC12", 1)
    assert ntfy.SENT_LOG == [
        {
            "topic": "flariane-test-topic",
            "title": "Nouvelle demande de devis",
            "message": "Commande FLR-ABC12 à chiffrer",
            "priority": 3,
            "tags": ["bell"],
        }
    ]


async def test_money_events_ring_louder(topic: None) -> None:
    await tasks.push_admins("payment_held", "FLR-ABC12", 1)
    await tasks.push_admins("payment_received", "FLR-ABC12", 1)
    assert [m["priority"] for m in ntfy.SENT_LOG] == [5, 4]


async def test_ntfy_failure_does_not_block_fcm(topic: None, monkeypatch: pytest.MonkeyPatch) -> None:
    async def boom(*args: object, **kwargs: object) -> None:
        raise RuntimeError("ntfy down")

    monkeypatch.setattr(ntfy, "send", boom)
    await tasks.push_admins("quote_requested", "FLR-ABC12", 1)  # must not raise


# ---- "Tester les alertes": a super admin checks the whole chain from the app


async def test_admin_can_send_a_test_alert(client, admin, topic: None) -> None:  # type: ignore[no-untyped-def]
    r = await client.post("/admin/ntfy/test", headers=admin.headers)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["sent"] is True and body["topic_length"] == len("flariane-test-topic")
    # Enough of the topic to compare with the ntfy app, never the whole secret.
    assert body["topic_hint"].startswith("fl") and body["topic_hint"].endswith("ic") and "flariane-test-topic" not in body["topic_hint"]
    assert ntfy.SENT_LOG[-1]["title"] == "Test d’alerte Flariane"


async def test_test_alert_says_when_no_topic_is_set(client, admin) -> None:  # type: ignore[no-untyped-def]
    r = await client.post("/admin/ntfy/test", headers=admin.headers)
    assert r.status_code == 400 and r.json()["detail"] == "ntfy_not_configured"


async def test_test_alert_reports_a_refusal_from_ntfy(client, admin, topic: None, monkeypatch: pytest.MonkeyPatch) -> None:  # type: ignore[no-untyped-def]
    async def refused(*args: object, **kwargs: object) -> None:
        raise ntfy.NtfyError("ntfy answered 403: forbidden")

    monkeypatch.setattr(ntfy, "send", refused)
    r = await client.post("/admin/ntfy/test", headers=admin.headers)
    assert r.status_code == 200 and r.json()["sent"] is False and "403" in r.json()["error"]


async def test_only_super_admins_can_test_alerts(client, topic: None) -> None:  # type: ignore[no-untyped-def]
    from tests.conftest import make_admin

    operator = await make_admin(role="OPERATOR", email="op@flariane.ci")
    assert (await client.post("/admin/ntfy/test", headers=operator.headers)).status_code == 403
    assert (await client.post("/admin/ntfy/test")).status_code == 401
