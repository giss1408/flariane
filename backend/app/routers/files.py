"""Serves stored screenshots (local disk or S3/R2) through short-lived signed URLs."""

import mimetypes

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
from starlette.concurrency import run_in_threadpool

from app.integrations import storage

router = APIRouter(tags=["files"])


@router.get("/files/{key:path}")
async def get_file(key: str, exp: int, sig: str) -> Response:
    data = await run_in_threadpool(storage.read_signed, key, exp, sig)  # S3 reads block
    if data is None:
        raise HTTPException(status_code=404)
    content_type = mimetypes.guess_type(key)[0] or "application/octet-stream"
    return Response(
        data,
        media_type=content_type,
        headers={"Cache-Control": "private, max-age=86400, immutable", "X-Content-Type-Options": "nosniff"},
    )
