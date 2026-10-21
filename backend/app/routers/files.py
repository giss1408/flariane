"""Serves locally stored screenshots through short-lived signed URLs (dev / local storage only;
S3 storage uses presigned URLs instead)."""

import mimetypes

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response

from app.integrations import storage

router = APIRouter(tags=["files"])


@router.get("/files/{key:path}")
async def get_file(key: str, exp: int, sig: str) -> Response:
    data = storage.read_local_signed(key, exp, sig)
    if data is None:
        raise HTTPException(status_code=404)
    content_type = mimetypes.guess_type(key)[0] or "application/octet-stream"
    return Response(
        data,
        media_type=content_type,
        headers={"Cache-Control": "private, max-age=300", "X-Content-Type-Options": "nosniff"},
    )
