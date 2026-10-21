import time
from decimal import Decimal

import pytest

from app.errors import BadRequest
from app.integrations import wave, whatsapp
from app.services.links import extract_shein_urls, log_safe, product_id_from_url
from app.services.customer_auth import normalize_ci_phone
from app.services.pricing import LineInput, compute_quote, default_customs, to_xof

SECRET = "s3cret"


class TestLinks:
    def test_extracts_cart_share_from_marketing_text(self) -> None:
        text = "Regarde mon panier SHEIN ! https://onelink.shein.com/57/65rpbi9ni43f?shc=2_RNw3pcqAELu"
        assert extract_shein_urls(text) == ["https://onelink.shein.com/57/65rpbi9ni43f?shc=2_RNw3pcqAELu"]

    @pytest.mark.parametrize(
        "url",
        [
            "https://evil.com/x",
            "https://shein.com.evil.com/a",
            "https://user@m.shein.com/x",
            "https://m.shein.com:99999/x",
            "https://m.shein.com:8443/x",
            "http://onelink.shein.com/57/a",
            "https://onelink.shein.com/../../etc",
        ],
    )
    def test_rejects(self, url: str) -> None:
        assert extract_shein_urls(url) == []

    def test_accepts_website_links_and_dedupes(self) -> None:
        u = "https://m.shein.com/fr/robe-p-12345.html"
        assert extract_shein_urls(f"{u} et {u}.") == [u]
        assert product_id_from_url(u) == "12345"

    def test_log_safe_hides_token(self) -> None:
        assert log_safe("https://onelink.shein.com/57/65rpbi9ni43f?shc=2_RNw3pcqAELu") == "onelink.shein.com/…AELu"


class TestPricing:
    def test_rounds_up_each_unit_price(self) -> None:
        fx = {"EUR": "655.957"}
        assert to_xof(Decimal("12.99"), "EUR", fx) == 8521  # 8520.88 -> 8521
        q = compute_quote(
            [LineInput(1, Decimal("12.99"), "EUR"), LineInput(2, Decimal("8.50"), "EUR")],
            fx, freight_xof=9000, customs_xof=3000, fee_xof=2500,
        )
        assert q.items_xof == 8521 + 2 * 5576
        assert q.total_xof == q.items_xof + 9000 + 3000 + 2500

    def test_missing_rate_is_an_error(self) -> None:
        with pytest.raises(ValueError):
            to_xof(Decimal("1"), "GBP", {"EUR": "655.957"})

    def test_negative_amounts_rejected(self) -> None:
        with pytest.raises(ValueError):
            compute_quote([], {}, freight_xof=-1, customs_xof=0, fee_xof=0)

    def test_customs_rounds_up(self) -> None:
        assert default_customs(1001, 20) == 201


class TestPhone:
    @pytest.mark.parametrize("raw", ["0701020304", "07 01 02 03 04", "+225 07 01 02 03 04", "002250701020304", "2250701020304"])
    def test_normalises(self, raw: str) -> None:
        assert normalize_ci_phone(raw) == "+2250701020304"

    @pytest.mark.parametrize("raw", ["070102030", "2701020304", "+33612345678", "abc", ""])
    def test_rejects(self, raw: str) -> None:
        with pytest.raises(BadRequest):
            normalize_ci_phone(raw)


class TestWaveSignature:
    body = b'{"id":"EV_1"}'

    def test_valid(self) -> None:
        assert wave.verify_signature(wave.sign_payload(self.body, SECRET), self.body, SECRET, 300)

    def test_second_v1_valid(self) -> None:
        good = wave.sign_payload(self.body, SECRET)
        t, v1 = good.split(",")
        assert wave.verify_signature(f"{t},v1=deadbeef,{v1}", self.body, SECRET, 300)

    @pytest.mark.parametrize(
        "header",
        [None, "", "garbage", "t=abc,v1=00", "t=1,v1=", f"t={int(time.time())},v1=é"],
    )
    def test_malformed(self, header: str | None) -> None:
        assert not wave.verify_signature(header, self.body, SECRET, 300)

    def test_wrong_secret_tampered_body_and_stale(self) -> None:
        assert not wave.verify_signature(wave.sign_payload(self.body, "other"), self.body, SECRET, 300)
        assert not wave.verify_signature(wave.sign_payload(self.body, SECRET), self.body + b" ", SECRET, 300)
        old = int(time.time()) - 1000
        assert not wave.verify_signature(wave.sign_payload(self.body, SECRET, old), self.body, SECRET, 300)


def test_whatsapp_signature() -> None:
    import hashlib
    import hmac

    body = b'{"entry":[]}'
    sig = "sha256=" + hmac.new(b"app", body, hashlib.sha256).hexdigest()
    assert whatsapp.verify_signature(sig, body, "app")
    assert not whatsapp.verify_signature(sig, body + b"x", "app")
    assert not whatsapp.verify_signature(sig, body, "")
    assert not whatsapp.verify_signature("sha1=abc", body, "app")


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("postgres://u:p@h:5432/db", "postgresql+asyncpg://u:p@h:5432/db"),
        ("postgresql://u:p@h/db?sslmode=require", "postgresql+asyncpg://u:p@h/db?ssl=require"),
        ("postgresql+asyncpg://u:p@h/db", "postgresql+asyncpg://u:p@h/db"),
        (
            "postgresql://u:p@ep-cool-1-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require&channel_binding=require",
            "postgresql+asyncpg://u:p@ep-cool-1-pooler.eu-central-1.aws.neon.tech/neondb?ssl=require",
        ),
    ],
)
def test_database_url_normalised(raw: str, expected: str) -> None:
    from app.config import Settings

    assert Settings._asyncpg_url(raw) == expected


def test_dev_routes_never_in_prod() -> None:
    from app.config import Settings

    base = {"jwt_secret": "x" * 32, "field_encryption_key": "k", "hash_key": "k", "wave_webhook_secret": "secret12"}
    assert Settings(env="prod", dev_routes=True, **base).dev_routes_enabled is False
    assert Settings(env="staging", **base).dev_routes_enabled is False
    assert Settings(env="staging", dev_routes=True, **base).dev_routes_enabled is True
    assert Settings(env="dev", **base).dev_routes_enabled is True


def test_temu_links() -> None:
    from app.services.links import pick_cart_url, store_of

    text = "Regarde mon panier Temu https://share.temu.com/abcDEF123 !"
    urls = extract_shein_urls(text)
    assert urls == ["https://share.temu.com/abcDEF123"]
    assert store_of(urls[0]) == "TEMU" and pick_cart_url(urls) == urls[0]
    assert extract_shein_urls("https://temu.com.evil.io/x") == []
    assert store_of("https://onelink.shein.com/57/abc") == "SHEIN"


@pytest.mark.parametrize(
    "raw,expected",
    [("+49 151 23456789", "+4915123456789"), ("0049 1761234567", "+491761234567"), ("+49 (0)160 1234567", "+491601234567")],
)
def test_german_test_numbers(raw: str, expected: str) -> None:
    assert normalize_ci_phone(raw) == expected


def test_german_numbers_refused_in_prod(monkeypatch: pytest.MonkeyPatch) -> None:
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "env", "prod")
    with pytest.raises(BadRequest):
        normalize_ci_phone("+4915123456789")
