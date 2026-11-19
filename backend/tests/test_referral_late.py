"""Referral code applied after sign-up (accounts created through auth cannot pass it at registration)."""

from httpx import AsyncClient

from tests.conftest import AdminFixture, create_order, login_customer

FRIEND = "0507080910"


async def points(client, h):
    return (await client.get("/me/loyalty", headers=h)).json()


async def test_code_applied_after_signup_credits_the_referrer_once(client: AsyncClient, customer: dict) -> None:
    code = (await points(client, customer))["referral_code"]
    friend = await login_customer(client, FRIEND, "Aya")  # verified number (the helper stands in for the admin code)
    assert (await client.post("/me/referral", json={"code": code.lower()}, headers=friend)).status_code == 200
    info = await points(client, customer)
    assert info["balance"] == 1 and info["history"][0]["kind"] == "REFERRAL_SIGNUP" and info["history"][0]["friend_name"] == "Aya"
    again = await client.post("/me/referral", json={"code": code}, headers=friend)
    assert again.status_code == 409 and again.json()["detail"] == "referral_already_set"
    assert (await points(client, customer))["balance"] == 1  # not credited twice


async def test_unknown_own_and_late_codes_are_refused(client: AsyncClient, customer: dict, pickup_point) -> None:
    friend = await login_customer(client, FRIEND, "Aya")
    assert (await client.post("/me/referral", json={"code": "NOPE-1234"}, headers=friend)).json()["detail"] == "referral_code_invalid"
    own = (await points(client, friend))["referral_code"]
    assert (await client.post("/me/referral", json={"code": own}, headers=friend)).json()["detail"] == "referral_code_invalid"
    code = (await points(client, customer))["referral_code"]
    await create_order(client, friend, pickup_point)
    late = await client.post("/me/referral", json={"code": code}, headers=friend)
    assert late.status_code == 409 and late.json()["detail"] == "referral_too_late"
    assert (await points(client, customer))["balance"] == 0


async def test_referral_needs_a_session(client: AsyncClient) -> None:
    assert (await client.post("/me/referral", json={"code": "ABC-1234"})).status_code == 401
