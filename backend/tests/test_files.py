from httpx import AsyncClient

from app.config import get_settings
from app.integrations import storage


async def test_s3_files_are_served_through_the_api(client: AsyncClient, monkeypatch) -> None:  # type: ignore[no-untyped-def]
    """Production uses R2: phones and the admin app must get an API link, not a direct bucket link."""
    monkeypatch.setattr(get_settings(), "storage_mode", "s3")
    monkeypatch.setattr(storage, "get", lambda key: b"jpeg-bytes" if key == "orders/1/a.jpg" else None)

    url = storage.signed_url("orders/1/a.jpg")
    assert url.startswith(get_settings().api_base_url + "/files/orders/1/a.jpg?")
    path = url[len(get_settings().api_base_url):]

    ok = await client.get(path)
    assert ok.status_code == 200 and ok.content == b"jpeg-bytes" and ok.headers["content-type"] == "image/jpeg"
    # A tampered signature, a different key and a missing object are all refused.
    assert (await client.get(path.replace("sig=", "sig=0"))).status_code == 404
    assert (await client.get(path.replace("a.jpg", "b.jpg"))).status_code == 404
    other = storage.signed_url("orders/1/missing.jpg")
    assert (await client.get(other[len(get_settings().api_base_url):])).status_code == 404
