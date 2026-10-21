"""Private storage for cart screenshots. Admins read files only through short-lived signed URLs."""

import hashlib
import hmac
import io
import time
import uuid
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from app.config import get_settings
from app.errors import BadRequest
from app.security.crypto import _key

ALLOWED_FORMATS = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}
SIGNED_URL_SECONDS = 3600  # long enough for a customer reading her quote


def sanitize_image(data: bytes) -> tuple[bytes, str, str]:
    """Validate by decoding (never trust the declared type) and re-encode to strip EXIF/GPS metadata."""
    if len(data) > get_settings().max_upload_mb * 1024 * 1024:
        raise BadRequest("file_too_large")
    try:
        img = Image.open(io.BytesIO(data))
        img.verify()
        img = Image.open(io.BytesIO(data))
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError):
        raise BadRequest("invalid_image") from None
    fmt = img.format or ""
    if fmt not in ALLOWED_FORMATS:
        raise BadRequest("unsupported_image_type", "JPEG, PNG ou WebP")
    if img.width * img.height > 40_000_000:
        raise BadRequest("image_too_large")
    if fmt == "JPEG" and img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    out = io.BytesIO()
    # Pillow writes no EXIF/XMP/text chunks unless explicitly passed, so re-saving strips metadata.
    img.save(out, format=fmt)
    ext = {"JPEG": "jpg", "PNG": "png", "WEBP": "webp"}[fmt]
    return out.getvalue(), ALLOWED_FORMATS[fmt], ext


def new_key(order_id: int, ext: str) -> str:
    return f"orders/{order_id}/{uuid.uuid4().hex}.{ext}"


def _s3():
    import boto3

    s = get_settings()
    return boto3.client(
        "s3",
        endpoint_url=s.s3_endpoint_url or None,
        aws_access_key_id=s.s3_access_key,
        aws_secret_access_key=s.s3_secret_key,
    )


def put(key: str, data: bytes, content_type: str) -> None:
    s = get_settings()
    if s.storage_mode == "s3":
        _s3().put_object(Bucket=s.s3_bucket, Key=key, Body=data, ContentType=content_type)
        return
    path = Path(s.storage_local_dir) / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _local_sig(key: str, exp: int) -> str:
    return hmac.new(_key("hash_key"), f"file:{key}:{exp}".encode(), hashlib.sha256).hexdigest()


def signed_url(key: str) -> str:
    s = get_settings()
    if s.storage_mode == "s3":
        return _s3().generate_presigned_url(
            "get_object", Params={"Bucket": s.s3_bucket, "Key": key}, ExpiresIn=SIGNED_URL_SECONDS
        )
    exp = int(time.time()) + SIGNED_URL_SECONDS
    return f"{s.api_base_url}/files/{key}?exp={exp}&sig={_local_sig(key, exp)}"


def read_local_signed(key: str, exp: int, sig: str) -> bytes | None:
    if exp < time.time() or not hmac.compare_digest(_local_sig(key, exp), sig):
        return None
    base = Path(get_settings().storage_local_dir).resolve()
    path = (base / key).resolve()
    if base not in path.parents or not path.is_file():
        return None
    return path.read_bytes()
