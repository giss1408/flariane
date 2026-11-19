FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
# Shared platform kit (build context `kit` is declared in compose.platform.yaml). Pin by git tag once the kit has a remote.
COPY --from=kit . /kit
RUN pip install "/kit[sso]"
COPY alembic.ini .
COPY alembic ./alembic
COPY app ./app
RUN useradd --create-home --uid 10001 flariane && mkdir -p /app/var/uploads && chown -R flariane /app/var
USER flariane
EXPOSE 8000
# Behind Caddy (and Cloudflare in production): real client IP comes from X-Forwarded-For via FLR_TRUSTED_PROXY_HOPS.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 2 --proxy-headers --forwarded-allow-ips='*'"]
