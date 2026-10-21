# Integrations

API details below reflect Wave's and Meta's public docs at time of writing. Check the current
docs before shipping (Wave: docs.wave.com; WhatsApp: developers.facebook.com/docs/whatsapp).

## Wave Checkout

**Create a session** when the customer accepts a quote:

```
POST https://api.wave.com/v1/checkout/sessions
Authorization: Bearer <WAVE_API_KEY>
Idempotency-Key: <payments.idempotency_key>
Content-Type: application/json

{ "amount": "25000", "currency": "XOF",
  "client_reference": "<orders.public_ref>",
  "success_url": "https://app.flariane.ci/orders/<public_ref>?paid=1",
  "error_url":   "https://app.flariane.ci/orders/<public_ref>?failed=1" }
```

- `amount` comes from the stored quote total, never from the request body.
- Store `id` as `checkout_session_id`; send the customer to `wave_launch_url`.
- `success_url` only shows a "Confirming your payment…" screen that polls our API. It never
  changes status.
- Sessions expire; on expiry mark the payment `EXPIRED` and let the customer start a new one
  (new idempotency key).

**Webhook events** used: `checkout.session.completed`, `checkout.session.payment_failed`.

**Signature:** header `Wave-Signature: t=<unix>,v1=<hex>[,v1=<hex>]`.
Expected = HMAC-SHA256(webhook_secret, `<t>` + `<raw body>`), hex. Accept if any `v1` matches.

### Webhook verification + idempotency (FastAPI)

Verify the signature on the raw bytes from `await request.body()` **before** parsing JSON —
never declare the payload as a Pydantic body parameter on this route.

```python
# app/webhooks/wave.py
import hashlib
import hmac
import json
import time

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import func, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_session
from app.models import WebhookEvent
from app.payments.service import apply_wave_event

TOLERANCE_SECONDS = 300
router = APIRouter()


async def verified_wave_body(request: Request) -> bytes:
    header = request.headers.get("wave-signature")
    body = await request.body()
    if not header:
        raise HTTPException(status_code=401)

    parts = [p.split("=", 1) for p in header.split(",") if "=" in p]
    t = next((v for k, v in parts if k == "t"), None)
    sigs = [v for k, v in parts if k == "v1"]
    if not t or not t.isdigit() or not sigs:
        raise HTTPException(status_code=401)

    # Reject replays of old, validly signed requests.
    if abs(time.time() - int(t)) > TOLERANCE_SECONDS:
        raise HTTPException(status_code=401)

    expected = hmac.new(
        settings.wave_webhook_secret.encode(), t.encode() + body, hashlib.sha256
    ).hexdigest().encode()
    if not any(hmac.compare_digest(expected, s.encode()) for s in sigs):
        raise HTTPException(status_code=401)  # also emit a security alert here
    return body


@router.post("/webhooks/wave")
async def wave_webhook(
    body: bytes = Depends(verified_wave_body),
    db: AsyncSession = Depends(get_session),
):
    event = json.loads(body)
    async with db.begin():
        # Dedupe: the unique (provider, event_id) constraint makes retries a no-op.
        row_id = await db.scalar(
            insert(WebhookEvent)
            .values(provider="WAVE", event_id=event["id"], type=event["type"])
            .on_conflict_do_nothing(index_elements=["provider", "event_id"])
            .returning(WebhookEvent.id)
        )
        if row_id is None:
            return {"received": True, "duplicate": True}

        # Amount/currency check, state transition, audit log and order update.
        # Notifications are enqueued (Celery), never sent inline.
        await apply_wave_event(db, event)
        await db.execute(
            update(WebhookEvent).where(WebhookEvent.id == row_id).values(processed_at=func.now())
        )
    return {"received": True}
```

Dedupe row, payment update and audit log commit in **one transaction**. If
`apply_wave_event` raises, everything rolls back — including the dedupe row — the endpoint
returns 500 and Wave's retry is processed normally. Keep the handler fast: no outbound calls.

## WhatsApp (Cloud API)

- Business-initiated messages need **pre-approved templates**. Category `utility` for order
  updates. No OTP/authentication templates (login is phone + password). Register `fr` first, `en` second.
- Customer replies open a 24-hour window for free-form messages; outside it, templates only.
- Verify inbound webhooks: header `X-Hub-Signature-256: sha256=<hex>` = HMAC-SHA256(app_secret,
  raw body). Same dependency pattern as Wave, without the timestamp.
- Send through a Celery task with retries and backoff; store the WhatsApp message id and delivery status.

Templates:

| Name | Trigger | Text (fr) |
|---|---|---|
| `quote_ready` | `QUOTED` | Bonjour {{1}}, votre devis {{2}} est prêt : {{3}} FCFA, valable jusqu'au {{4}}. |
| `payment_received` | `PAID` | Paiement reçu pour la commande {{1}}. Nous lançons l'achat. |
| `order_ready_pickup` | `READY_FOR_PICKUP` | Bonjour {{1}}, votre commande {{2}} est arrivée à {{3}}. Horaires : {{4}}. Code de retrait : {{5}}. |
| `item_cancelled` | `PARTIALLY_FULFILLED` | Un article de la commande {{1}} n'est plus disponible. Remboursement de {{2}} FCFA en cours. |

Pickup is confirmed by the agent entering the pickup code in the admin app — not by a
customer reply.

## Importing a SHEIN cart

Customers fill their cart in the SHEIN app and use its **cart share**, which produces a short
link. That cart link is the primary input — one link per order. Product short links and cart
screenshots are fallbacks.

| Method | How it arrives | Role |
|---|---|---|
| **Cart share link** | SHEIN cart → Share → Flariane (Android Web Share Target / Flutter share intent; iOS Share Extension in Flutter) or copy-paste | Primary. One link = whole cart |
| Product share links | Same channels; text field accepts many URLs at once | Fallback, e.g. items from several carts |
| Cart screenshot(s) | Image upload | Fallback, and evidence of what the customer saw |

Intake rules (API):

Real cart share link (observed Oct 2026):
`https://onelink.shein.com/57/65rpbi9ni43f?shc=2_RNw3pcqAELu`

- It is an AppsFlyer OneLink. It returns **HTTP 200 with a JavaScript redirect** to
  `api-shein.shein.com/h5/sharejump/appjump?...`, which is again a JS page that opens the SHEIN
  app or web cart. There is no HTTP redirect chain to follow.
- So the server **never fetches share links** — no resolving, no page parsing. This also
  removes SSRF risk from intake. The link is validated, stored as-is, and opened by the admin
  in a browser.

- Shares arrive as marketing text with a URL inside: extract every URL from the text.
- Accept a URL only if: scheme `https`, no userinfo, no port, and host is `onelink.shein.com`
  (app shares) or ends with `.shein.com` / equals `shein.com` (links copied from the website).
  Reject everything else with a friendly message.
- Treat the path and `shc` query as an opaque token: store the URL exactly as shared in
  `source_cart_url`. Don't log it in full (it gives access to the customer's cart); log host +
  last 4 chars.
- Deduplicate: the same `source_cart_url` submitted twice by the same customer within 24 h
  returns the existing open order.

```python
# app/carts/links.py
import re
from urllib.parse import urlsplit

URL_RE = re.compile(r"https?://[^\s<>\"']+")
SHEIN_SHARE = re.compile(r"^https://onelink\.shein\.com/\d+/[A-Za-z0-9]+(\?[\w=&%.-]*)?$", re.ASCII)


def extract_shein_urls(text: str) -> list[str]:
    urls = []
    for raw in URL_RE.findall(text):
        try:
            u = urlsplit(raw)
            port = u.port  # raises ValueError on a malformed port
        except ValueError:
            continue
        if u.scheme != "https" or u.username or u.password or port:
            continue
        host = (u.hostname or "").lower()
        if host == "onelink.shein.com":
            if SHEIN_SHARE.match(raw):
                urls.append(raw)
        elif host == "shein.com" or host.endswith(".shein.com"):
            urls.append(raw)
    return urls
```

Open questions to verify with real shares and record here:
- Does the cart link still open after 24 h / 7 days? If it expires fast, require a cart
  screenshot at submit.
- Opened in the admin's SHEIN app, can the items be added to the admin's cart with the
  customer's size and colour kept, or must they be re-selected by hand?
- Do product shares use the same `onelink.shein.com/<n>/<id>` shape?

Quoting (admin mobile app — full rules in `admin-app.md`):

- The admin taps the cart link in the admin app; it opens **in the SHEIN app on the same
  phone**. Then the admin enters each line in the quote editor: title, size, colour, qty,
  SHEIN price. Screenshots, if any, show on the order screen.
- **No automatic reading of the shared cart page** (no scraping, no headless browser). Revisit
  only if quoting time becomes the bottleneck, and only after checking SHEIN's terms.
- Deduplicate identical product + size + colour into one line with summed qty.

Customer confirmation:

- The quote shows every line with size, colour and qty. The customer must tick "Tailles et
  couleurs vérifiées" before accepting; a wrong size is the most expensive mistake (no returns).
- "Modifier ma commande" sends a change request (new cart link, removed lines, size/colour/qty
  fixes, note) → order back to `QUOTE_REQUESTED`, admin drafts the next quote version.

Screenshots: images only (JPEG/PNG/WebP/HEIC), max 10 MB each, max 10 per order, strip EXIF,
private bucket, admins view via short-lived signed URLs.

## SHEIN purchase flow (admin)

SHEIN has no purchasing API. Purchases are made **by hand in the SHEIN app** on the admin's
phone, from the business SHEIN account. The admin mobile app tracks that work; it never
touches SHEIN.

1. **Purchase checklist** (admin app, "À acheter" tab): orders in `PAID`, oldest first. Each
   card shows `public_ref`, the cart link (tap to open in the SHEIN app) and the **accepted
   quote's** lines with size, colour, qty as a checklist.
2. Admin opens the link in the SHEIN app, adds the items to the business cart, and ticks each
   line in the app after checking size and colour against the accepted quote — the quote, not
   the live SHEIN cart, is what the customer approved.
3. Admin checks out in SHEIN. Ship-to = the freight forwarder's warehouse address; put the
   `public_ref` in the recipient line (e.g. "FLR-7K3Q9 / Flariane") so the forwarder can sort
   parcels.
4. Admin records in the app: `store_order_ref`, amount actually paid, currency, and any line
   SHEIN refused → order `PURCHASED`. The app shows margin vs the quote and flags losses.
5. If the SHEIN price went up since the quote by more than the margin buffer, stop before
   paying SHEIN: absorb it, or contact the customer (pay the difference or refund) — the app
   asks which, and logs the decision.
6. Lines SHEIN cancels later are marked `CANCELLED_BY_STORE`; the system computes the refund
   and moves the order to `PARTIALLY_FULFILLED` or `REFUND_PENDING`.
7. Purchased orders are added to the open weekly shipment.

Mapping rule: **one SHEIN order per Flariane order** at first — simple to reconcile and sort.
Combining several customers into one SHEIN order (to reach free-shipping thresholds) needs
`store_purchases` ↔ `order_items` mapping per line; add it only when the savings are proven.

Never store SHEIN account credentials in the app, and never automate the SHEIN app or website.
