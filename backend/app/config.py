from functools import lru_cache
from typing import Literal

from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """All secrets come from the environment (Doppler in production, .env locally)."""

    model_config = SettingsConfigDict(env_file=".env", env_prefix="FLR_", extra="ignore")

    env: Literal["dev", "test", "staging", "prod"] = "dev"
    # Test-only routes (simulated Wave checkout page). Default: on in dev only.
    # Never mounted in prod, whatever this says.
    dev_routes: bool | None = None
    api_base_url: str = "http://localhost:8000"
    customer_app_url: str = "http://localhost:3000"
    cors_origins: list[str] = ["http://localhost:3000", "http://localhost:3001"]

    database_url: str = "postgresql+asyncpg://flariane:flariane@localhost:5433/flariane"
    redis_url: str = "redis://localhost:6380/0"

    # Crypto. Keys are base64-encoded 32 random bytes.
    jwt_secret: str = Field(min_length=32)
    field_encryption_key: str
    hash_key: str
    access_token_minutes: int = 15
    customer_refresh_days: int = 30
    admin_refresh_hours: int = 12

    # Wave
    wave_mode: Literal["fake", "live"] = "fake"
    wave_api_key: str = ""
    wave_webhook_secret: str = Field(min_length=8)
    wave_api_base: str = "https://api.wave.com"
    webhook_tolerance_seconds: int = 300

    # WhatsApp Cloud API
    whatsapp_mode: Literal["log", "live"] = "log"
    whatsapp_token: str = ""
    whatsapp_phone_number_id: str = ""
    whatsapp_app_secret: str = ""
    whatsapp_verify_token: str = ""
    whatsapp_api_version: str = "v21.0"

    # Push (FCM HTTP v1)
    push_mode: Literal["log", "live"] = "log"
    fcm_project_id: str = ""
    fcm_service_account_json: str = ""

    # File storage for cart screenshots
    storage_mode: Literal["local", "s3"] = "local"
    storage_local_dir: str = "./var/uploads"
    s3_bucket: str = ""
    s3_endpoint_url: str = ""
    s3_access_key: str = ""
    s3_secret_key: str = ""
    max_upload_mb: int = 10
    max_attachments_per_order: int = 10

    rate_limit_storage: str = "memory://"

    # One-time creation of the first super admin over HTTP (hosts without a shell). Empty = disabled.
    setup_token: str = ""

    # How background tasks run: Celery workers in production, in-process in dev, recorded in tests.
    task_mode: Literal["celery", "inline", "record"] = "inline"

    @field_validator("database_url")
    @classmethod
    def _asyncpg_url(cls, v: str) -> str:
        """Render/Neon give postgres://…?sslmode=require[&channel_binding=require]; SQLAlchemy+asyncpg
        wants postgresql+asyncpg://…?ssl=require and rejects channel_binding."""
        parts = urlsplit(v)
        scheme = "postgresql+asyncpg" if parts.scheme in ("postgres", "postgresql") else parts.scheme
        query = [
            ("ssl", val) if key == "sslmode" else (key, val)
            for key, val in parse_qsl(parts.query)
            if key != "channel_binding"
        ]
        return urlunsplit((scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))

    @property
    def dev_routes_enabled(self) -> bool:
        if self.env == "prod":
            return False
        return self.dev_routes if self.dev_routes is not None else self.env == "dev"


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
