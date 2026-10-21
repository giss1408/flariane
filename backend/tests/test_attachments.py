import io

from httpx import AsyncClient
from PIL import Image

from tests.conftest import AdminFixture, create_order, order_id


def jpeg_with_exif() -> bytes:
    img = Image.new("RGB", (40, 40), "red")
    exif = Image.Exif()
    exif[0x010F] = "SecretPhoneMaker"  # Make
    buf = io.BytesIO()
    img.save(buf, format="JPEG", exif=exif.tobytes())
    return buf.getvalue()


async def test_screenshot_upload_strips_metadata_and_signs_urls(client: AsyncClient, customer: dict, admin: AdminFixture, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    raw = jpeg_with_exif()
    assert b"SecretPhoneMaker" in raw
    r = await client.post(f"/orders/{ref}/attachments", files={"file": ("cart.jpg", raw, "image/jpeg")}, headers=customer)
    assert r.status_code == 201, r.text

    detail = (await client.get(f"/admin/orders/{await order_id(ref)}", headers=admin.headers)).json()
    url = detail["attachments"][0]["url"]
    path = url.split("http://localhost:8000", 1)[1]
    r = await client.get(path)
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"
    assert b"SecretPhoneMaker" not in r.content

    tampered = path.replace("sig=", "sig=0")
    assert (await client.get(tampered)).status_code == 404


async def test_non_image_rejected(client: AsyncClient, customer: dict, pickup_point) -> None:  # type: ignore[no-untyped-def]
    ref = (await create_order(client, customer, pickup_point))["public_ref"]
    r = await client.post(f"/orders/{ref}/attachments", files={"file": ("cart.jpg", b"<script>alert(1)</script>", "image/jpeg")}, headers=customer)
    assert r.status_code == 400 and r.json()["detail"] == "invalid_image"
