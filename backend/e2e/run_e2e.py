"""End-to-end run of the whole Flariane flow against a deployed TEST server (never production).

    E2E_API_URL=https://flariane-api-test.onrender.com \
    E2E_ADMIN_EMAIL=... E2E_ADMIN_PASSWORD=... E2E_ADMIN_TOTP_SECRET=... \
    .venv/bin/python e2e/run_e2e.py

Needs a dedicated SUPER_ADMIN. Its device is registered once and kept in e2e/.state.json (gitignored).
Everything the run creates uses throwaway +49 customers and is deleted at the end.
Exit code 0 only if every check passed.
"""

import io
import json
import os
import random
import re
import sys
import time
from datetime import date, timedelta
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

import httpx
import pyotp
from PIL import Image

API = os.environ.get("E2E_API_URL", "").rstrip("/")
PROD_HOSTS = {"flariane-api.onrender.com", "api.flariane.ci"}
STATE = Path(__file__).with_name(".state.json")
PASSWORD = "e2e-Secret-2026"
CART = "Regarde mon panier SHEIN ! https://onelink.shein.com/57/65rpbi9ni43f?shc=2_RNw3pcqAELu"

results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> bool:
    results.append((name, bool(ok), detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{'' if ok else '  -> ' + detail}", flush=True)
    return bool(ok)


def need(name: str, r: httpx.Response, status: int | tuple[int, ...] = 200) -> httpx.Response:
    wanted = (status,) if isinstance(status, int) else status
    check(name, r.status_code in wanted, f"{r.request.method} {r.request.url.path} -> {r.status_code} {r.text[:200]}")
    return r


def section(title: str) -> None:
    print(f"\n== {title}", flush=True)


def jpeg() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (40, 60), "orange").save(buf, format="JPEG")
    return buf.getvalue()


class Admin:
    def __init__(self, http: httpx.Client) -> None:
        self.http, self.h = http, {}

    def login(self) -> None:
        state = json.loads(STATE.read_text()) if STATE.exists() else {}
        device = {"name": "E2E runner", "platform": "android", **({"device_id": state["device_id"], "device_secret": state["device_secret"]} if state else {})}
        body = {"email": os.environ["E2E_ADMIN_EMAIL"], "password": os.environ["E2E_ADMIN_PASSWORD"], "device": device,
                "totp": pyotp.TOTP(os.environ["E2E_ADMIN_TOTP_SECRET"]).now()}
        r = self.http.post("/admin/auth/login", json=body)
        if r.status_code == 429 or r.status_code == 401:
            sys.exit(f"admin login refused ({r.status_code} {r.text[:120]}). Check the e2e credentials; a TOTP code works once, retry in 30 s.")
        out = r.json()
        if out.get("device_secret"):
            STATE.write_text(json.dumps({"device_id": out["device_id"], "device_secret": out["device_secret"]}))
        if out["status"] != "ok":
            sys.exit(f"E2E device {out['device_id']} is waiting for approval: approve it in the admin app (Compte > Appareils), then rerun.")
        self.h = {"Authorization": f"Bearer {out['tokens']['access_token']}"}

    def get(self, path: str, **kw) -> httpx.Response:
        return self.http.get(path, headers=self.h, **kw)

    def post(self, path: str, **kw) -> httpx.Response:
        return self.http.post(path, headers=self.h, **kw)

    def put(self, path: str, **kw) -> httpx.Response:
        return self.http.put(path, headers=self.h, **kw)

    def delete(self, path: str, **kw) -> httpx.Response:
        return self.http.delete(path, headers=self.h, **kw)


class Customer:
    def __init__(self, http: httpx.Client, admin: Admin, name: str, referral: str | None = None) -> None:
        self.http, self.admin, self.name = http, admin, name
        self.phone = f"+49 17{random.randint(1, 9)} {random.randint(10_000_000, 99_999_999)}"
        r = http.post("/auth/register", json={"phone": self.phone, "password": PASSWORD, "display_name": name, "consent": True,
                                              **({"referral_code": referral} if referral else {})})
        if r.status_code == 429:
            sys.exit("Registration rate limit hit (5 sign-ups per IP per hour; a run uses 3). Wait an hour, or raise FLR_REGISTER_PER_IP_HOUR on the test server.")
        need(f"{name}: register", r, 201)
        self.h = {"Authorization": f"Bearer {r.json()['access_token']}"}
        self.id = self.get("/me").json()["id"]

    def get(self, path: str, **kw) -> httpx.Response:
        return self.http.get(path, headers=self.h, **kw)

    def post(self, path: str, **kw) -> httpx.Response:
        return self.http.post(path, headers=self.h, **kw)

    def verify_phone(self) -> None:
        """The admin sends the code from their WhatsApp (wa.me link); the customer types it in the app."""
        r = need(f"{self.name}: admin issues the verification code", self.admin.post(f"/admin/customers/{self.id}/verification-code"))
        text = unquote(parse_qs(urlparse(r.json()["url"]).query)["text"][0])
        code = re.search(r"\*(\d{6})\*", text).group(1)  # type: ignore[union-attr]
        need(f"{self.name}: verifies the phone", self.post("/me/verify-phone", json={"code": code}), (200, 204))

    def order(self, point_id: int) -> tuple[str, int]:
        r = need(f"{self.name}: sends a cart", self.post("/orders", json={"share_text": CART + f" #{random.randint(1, 10**6)}", "pickup_point_id": point_id}), 201)
        ref = r.json()["public_ref"]
        oid = next(o["id"] for o in self.admin.get("/admin/orders", params={"tab": "to_quote"}).json() if o["public_ref"] == ref)
        return ref, oid


DRAFT = {"items": [{"title": "Robe midi", "size": "M", "color": "Bleu", "qty": 1, "source_price": "12.99", "source_currency": "EUR"}], "fee_xof": 3000}


def quote(admin: Admin, cust: Customer, ref: str, oid: int, draft: dict | None = None) -> dict:
    r = need("admin: saves the quote draft", admin.put(f"/admin/orders/{oid}/quote-draft", json=draft or DRAFT))
    version = r.json()["version"]
    need("admin: sends the quote", admin.post(f"/admin/orders/{oid}/quotes/{version}/send", json={}))
    q = cust.get(f"/orders/{ref}").json()
    check(f"{cust.name}: sees quote v{version} as QUOTED", q["status"] == "QUOTED" and q["quote"]["version"] == version, str(q.get("status")))
    return q


def pay(admin: Admin, cust: Customer, ref: str, oid: int, version: int = 1) -> None:
    need(f"{cust.name}: refuses to accept without ticking sizes", cust.post(f"/orders/{ref}/quotes/{version}/accept", json={"sizes_confirmed": False}), 400)
    need(f"{cust.name}: accepts the quote", cust.post(f"/orders/{ref}/quotes/{version}/accept", json={"sizes_confirmed": True}))
    need(f"{cust.name}: declares the Wave payment with proof", cust.post(f"/orders/{ref}/payment/declare", data={"method": "WAVE"}, files={"file": ("pay.jpg", jpeg(), "image/jpeg")}))
    check("admin: payment waits in 'to confirm'", ref in [o["public_ref"] for o in admin.get("/admin/orders", params={"tab": "to_confirm"}).json()])
    proof = admin.get(f"/admin/orders/{oid}/payment-proof")
    check("admin: sees the payment proof image", proof.status_code == 200 and proof.headers["content-type"].startswith("image/"), str(proof.status_code))
    need("admin: confirms the payment", admin.post(f"/admin/orders/{oid}/confirm-payment", json={"transaction_ref": "E2E-T1"}), 204)
    check(f"{cust.name}: order is PAID", cust.get(f"/orders/{ref}").json()["status"] == "PAID")


def purchase(admin: Admin, oid: int) -> None:
    items = [i["id"] for i in admin.get(f"/admin/orders/{oid}").json()["items"]]
    r = admin.post(f"/admin/orders/{oid}/purchase", json={"store_order_ref": "E2E-GSH1", "paid_amount": "12.99", "currency": "EUR"})
    check("admin: purchase refused until every line is checked", r.status_code == 400 and r.json().get("detail") == "checklist_incomplete", r.text[:150])
    need("admin: records the SHEIN purchase", admin.post(f"/admin/orders/{oid}/purchase", json={"store_order_ref": "E2E-GSH1", "paid_amount": "12.99", "currency": "EUR", "checked_item_ids": items}))


def main() -> int:
    if not API or urlparse(API).hostname in PROD_HOSTS:
        sys.exit("Set E2E_API_URL to the TEST server. Refusing to run against production.")
    for var in ("E2E_ADMIN_EMAIL", "E2E_ADMIN_PASSWORD", "E2E_ADMIN_TOTP_SECRET"):
        if not os.environ.get(var):
            sys.exit(f"{var} is not set")
    http = httpx.Client(base_url=API, timeout=120)
    created: list[Customer] = []
    admin = Admin(http)

    section("Server")
    t = time.time()
    need("health (may wake the Render instance)", http.get("/health"))
    print(f"      answered in {time.time() - t:.0f}s")
    info = http.get("/public/info").json()
    check("public info: support WhatsApp number is set", bool(info.get("support_whatsapp")), "Set 'support_whatsapp' in the admin settings")
    check("public info: payment accounts offered", bool(info.get("payment_accounts")), "No Wave number in settings")
    check("legal page: confidentialité reachable", http.get("/legal/confidentialite").status_code == 200)
    check("API docs are hidden when ENV=prod (informational, expected open on test)", True)
    check("admin routes refuse anonymous callers", http.get("/admin/orders").status_code == 401)
    admin.login()
    check("admin: logged in", bool(admin.h))
    me = admin.get("/admin/auth/me").json()
    check("admin: e2e account is SUPER_ADMIN", me.get("role") == "SUPER_ADMIN", str(me.get("role")))

    points = http.get("/pickup-points").json()
    if not points:
        points = [admin.post("/admin/pickup-points", json={"name": "E2E point", "address": "Rue 1", "commune": "Cocody", "opening_hours": "9h-19h"}).json()]
    point_id = points[0]["id"]

    section("A. Happy path: cart -> quote -> pay -> buy -> ship -> pickup")
    awa = Customer(http, admin, "E2E Awa")
    created.append(awa)
    ref0 = None
    r = awa.post("/orders", json={"share_text": CART, "pickup_point_id": point_id})
    check("unverified customer cannot order yet", r.status_code in (403, 409, 400), f"{r.status_code} {r.text[:150]}")
    check("admin: sees the registration to verify", awa.id in [c["id"] for c in admin.get("/admin/customers/unverified").json()])
    awa.verify_phone()
    loy = awa.get("/me/loyalty").json()
    check("loyalty: referral code assigned, balance 0", bool(loy["referral_code"]) and loy["balance"] == 0, str(loy))
    ref, oid = awa.order(point_id)
    check("admin: new order in the quote inbox with a push-able attention count", admin.get("/admin/orders/attention").status_code == 200)
    q = quote(admin, awa, ref, oid)
    total = q["quote"]["total_xof"]
    check("quote total is positive and in whole XOF", isinstance(total, int) and total > 0, str(total))
    pay(admin, awa, ref, oid)
    purchase(admin, oid)
    departure = (date(2040, 1, 1) + timedelta(days=random.randint(0, 3000))).isoformat()  # unique per run: a date can only be used once
    r = admin.post("/admin/shipments", json={"departure_date": departure})
    sid = need("admin: creates a shipment", r, (200, 201)).json()["id"]
    need("admin: adds the order to the shipment", admin.post(f"/admin/shipments/{sid}/orders", json={"order_ids": [oid]}))
    need("admin: shipment departs", admin.post(f"/admin/shipments/{sid}/depart", json={"tracking_ref": "E2E-AWB", "weight_kg": "1.2"}))
    check("customer: order IN_TRANSIT", awa.get(f"/orders/{ref}").json()["status"] == "IN_TRANSIT")
    need("admin: shipment arrives", admin.post(f"/admin/shipments/{sid}/arrive"))
    r = need("admin: order ready for pickup (code issued)", admin.post(f"/admin/orders/{oid}/ready-for-pickup", json={"pickup_point_id": point_id}))
    code = r.json()["code"]
    wrong = "000000" if code != "000000" else "111111"
    need("admin: wrong pickup code refused", admin.post(f"/admin/orders/{oid}/pickup", json={"code": wrong}), 400)
    check("customer: sees READY_FOR_PICKUP and her code", awa.get(f"/orders/{ref}").json()["status"] == "READY_FOR_PICKUP")
    need("admin: right pickup code accepted", admin.post(f"/admin/orders/{oid}/pickup", json={"code": code}), 204)
    check("customer: order PICKED_UP", awa.get(f"/orders/{ref}").json()["status"] == "PICKED_UP")
    loy = awa.get("/me/loyalty").json()
    check("loyalty: points earned for the collected order", loy["balance"] == loy["points_per_order"], str(loy["balance"]))
    export = awa.get("/me/export")
    check("data export works (law 2013-450)", export.status_code == 200 and len(export.text) > 20)
    intruder = Customer(http, admin, "E2E Intruder")
    created.append(intruder)
    check("another customer cannot read her order", intruder.get(f"/orders/{ref}").status_code in (403, 404))

    section("B. Change request -> second quote -> cancel")
    fatou = Customer(http, admin, "E2E Fatou", referral=loy["referral_code"])
    created.append(fatou)
    fatou.verify_phone()
    loy = awa.get("/me/loyalty").json()
    check("loyalty: referrer earns signup points when the friend is verified", loy["balance"] == loy["points_per_order"] + loy["points_referral_signup"], str(loy["balance"]))
    ref2, oid2 = fatou.order(point_id)
    quote(admin, fatou, ref2, oid2)
    lines = fatou.get(f"/orders/{ref2}").json()["quote"]["lines"]
    need("customer: asks for a size change", fatou.post(f"/orders/{ref2}/quotes/1/change-request", json={"line_changes": [{"order_item_id": lines[0]["order_item_id"], "size": "L"}], "note": "En L"}), 201)
    check("order goes back to QUOTE_REQUESTED", fatou.get(f"/orders/{ref2}").json()["status"] == "QUOTE_REQUESTED")
    r = fatou.post(f"/orders/{ref2}/quotes/1/accept", json={"sizes_confirmed": True})
    check("old quote can no longer be accepted", r.status_code == 409, f"{r.status_code}")
    item = admin.get(f"/admin/orders/{oid2}").json()["items"][0]
    d2 = {"items": [{"id": item["id"], "title": item["title"], "size": "L", "color": item["color"], "qty": 1, "source_price": "12.99", "source_currency": "EUR"}], "fee_xof": 3000}
    quote(admin, fatou, ref2, oid2, d2)
    need("customer: accepts quote v2", fatou.post(f"/orders/{ref2}/quotes/2/accept", json={"sizes_confirmed": True}))
    check("customer cannot cancel while payment is pending", fatou.post(f"/orders/{ref2}/cancel").status_code == 409)
    ref2b, oid2b = fatou.order(point_id)
    quote(admin, fatou, ref2b, oid2b)
    need("customer: cancels a quoted order she has not accepted", fatou.post(f"/orders/{ref2b}/cancel"), (200, 204))
    check("order CANCELLED", fatou.get(f"/orders/{ref2b}").json()["status"] == "CANCELLED")

    section("C. Refund of a paid order (super admin)")
    ref3, oid3 = fatou.order(point_id)
    quote(admin, fatou, ref3, oid3)
    pay(admin, fatou, ref3, oid3)
    r = need("admin: starts a full refund", admin.post(f"/admin/orders/{oid3}/refund", json={"reason": "E2E refund"}))
    check("order REFUND_PENDING", fatou.get(f"/orders/{ref3}").json()["status"] == "REFUND_PENDING")
    pending = [x for x in admin.get("/admin/refunds", params={"status": "PENDING"}).json() if x["order_ref"] == ref3]
    need("admin: completes the refund", admin.post(f"/admin/refunds/{pending[0]['id']}/complete", json={"external_ref": "E2E-R1"}))
    check("order REFUNDED", fatou.get(f"/orders/{ref3}").json()["status"] == "REFUNDED")

    section("D. Forgotten password")
    r = need("customer: asks for a new password (login screen)", http.post("/auth/password-reset-request", json={"phone": fatou.phone}), 202)
    need("unknown number gets the same answer", http.post("/auth/password-reset-request", json={"phone": "+49 176 00000001"}), 202)
    check("admin: request is in the queue", fatou.id in [x["id"] for x in admin.get("/admin/customers/password-resets").json()])
    r = need("admin: issues the temporary password", admin.post(f"/admin/customers/{fatou.id}/reset-password"))
    temp = r.json()["temporary_password"]
    check("admin: WhatsApp link carries the message", r.json()["url"].startswith("https://wa.me/") and temp in unquote(r.json()["url"]))
    check("old password no longer works", http.post("/auth/login", json={"phone": fatou.phone, "password": PASSWORD}).status_code == 401)
    r = need("customer: logs in with the temporary password", http.post("/auth/login", json={"phone": fatou.phone, "password": temp}))
    h = {"Authorization": f"Bearer {r.json()['access_token']}"}
    check("app is told to force a password change", http.get("/me", headers=h).json()["must_change_password"] is True)
    need("customer: sets a new password", http.post("/me/password", headers=h, json={"current_password": temp, "new_password": PASSWORD + "x"}), 204)
    check("queue is empty again", fatou.id not in [x["id"] for x in admin.get("/admin/customers/password-resets").json()])

    section("E. Customer management (super admin)")
    check("search by first name", fatou.id in [c["id"] for c in admin.get("/admin/customers", params={"q": "Fatou"}).json()])
    check("search by full phone number", fatou.id in [c["id"] for c in admin.get("/admin/customers", params={"q": fatou.phone}).json()])
    need("admin: blocks Fatou", admin.post(f"/admin/customers/{fatou.id}/block"), 204)
    check("blocked: her session stops at once", http.get("/me", headers=h).status_code == 401)
    r = http.post("/auth/login", json={"phone": fatou.phone, "password": PASSWORD + "x"})
    check("blocked: login says why", r.status_code == 401 and r.json().get("detail") == "account_blocked", r.text[:120])
    need("admin: unblocks Fatou", admin.post(f"/admin/customers/{fatou.id}/unblock"), 204)
    check("unblocked: she can log in again", http.post("/auth/login", json={"phone": fatou.phone, "password": PASSWORD + "x"}).status_code == 200)

    section("F. Cleanup (also tests account deletion)")
    for c in created:
        r = admin.delete(f"/admin/customers/{c.id}")
        check(f"admin: deletes {c.name}", r.status_code == 204, f"{r.status_code} {r.text[:120]}")
    # the intruder and any leftover
    for c in admin.get("/admin/customers", params={"q": "E2E"}).json():
        admin.delete(f"/admin/customers/{c['id']}")
    left = admin.get("/admin/customers", params={"q": "E2E"}).json()
    check("no E2E customer left behind", left == [], str([c["display_name"] for c in left]))
    admin.http.post("/admin/auth/logout", headers=admin.h)

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    for name, _, detail in failed:
        print(f"  FAILED: {name}  {detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
