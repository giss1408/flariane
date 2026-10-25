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
