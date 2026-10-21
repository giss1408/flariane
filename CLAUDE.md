# Flariane

Cross-border shopping service for Côte d'Ivoire: customers send a SHEIN product link or cart,
receive a price in XOF, pay with Wave, and collect the parcel at a pickup point in Abidjan.
The admin buys the items on SHEIN, consolidates them into weekly shipments, and notifies
customers on WhatsApp when parcels are ready.

For architecture, security, payment, WhatsApp and UI rules, use the `flariane-architect` skill.

## Business model (decided)

- **Customers shop inside the SHEIN app, then send their cart to Flariane; we quote.**
  Flariane has no catalog of its own: no SHEIN scraping, no copying SHEIN images, no "SHEIN"
  in the app name, icon or store listing. How a cart is imported: see the skill's
  `references/integrations.md` → "Importing a SHEIN cart".
- **Quote = items + freight + customs + service fee.** The admin enters the **service fee
  manually for each order** in the admin mobile app; freight and customs are pre-filled from
  settings and editable. Every quote locks its FX rate and expires (default 48h).
- **Nothing is bought until the customer accepts a quote and pays.** The customer can accept
  the quote or ask for changes; each change produces a new quote version.
- **Weekly consolidated shipments** (groupage). Promise realistic lead times (2–4 weeks).
- SHEIN is the first source, not the only one. The domain model must not assume a single store.

## Customer flow

1. Customer fills their cart in the SHEIN app and uses SHEIN's **cart share** to send the
   cart short link to Flariane (fallbacks: product links, cart screenshot) → order `QUOTE_REQUESTED`
2. Admin gets a push notification, opens the order in the **admin mobile app**, taps the cart
   link (opens in the SHEIN app on the same phone), enters the item lines (title, size, colour,
   qty, SHEIN price), checks freight/customs, **types the service fee**, previews the total and
   sends → quote v1 `SENT`, order `QUOTED` (WhatsApp + push to the customer)
3. Customer reviews every line and the price breakdown, then either:
   - **Accepts** (ticks "Tailles et couleurs vérifiées") → quote `ACCEPTED`, order
     `AWAITING_PAYMENT`, Wave checkout session created for exactly that quote's total; or
   - **Asks for changes** (new cart link, remove a line, fix size/colour/qty, note) → quote
     `CHANGE_REQUESTED`, order back to `QUOTE_REQUESTED`; admin is notified and sends quote v2.
   A quote not answered before `expires_at` → `EXPIRED`; the customer can request a fresh one.
4. Wave webhook confirms → `PAID`
5. Admin opens the cart link again in the SHEIN app, adds the items to the business account's
   cart, checks each line against the approved quote, and checks out manually (one SHEIN order
   per Flariane order, shipped to the forwarder with `public_ref` on the label), then records
   the SHEIN order ref and amount paid → `PURCHASED`
6. Assigned to a shipment → `IN_TRANSIT` → `ARRIVED` (Abidjan warehouse)
7. Sorted to pickup point → `READY_FOR_PICKUP` (WhatsApp utility template)
8. Collected with pickup code → `PICKED_UP`

Side exits: `CANCELLED` (before purchase), `PARTIALLY_FULFILLED` (SHEIN cancelled some items),
`REFUND_PENDING` → `REFUNDED`.

## Default stack (use unless told otherwise)

| Layer | Choice |
|---|---|
| Backend | Python 3.12, FastAPI, Pydantic v2, SQLAlchemy 2.0 (async, `asyncpg`) + Alembic migrations, `limits` rate limiting (Redis); served by Uvicorn; tests with `pytest` + `httpx` |
| Database | PostgreSQL (managed: Supabase or Neon). Access only through the API — no client-side DB access, so no RLS reliance |
| Cache / queues | Redis (Upstash) + Celery workers (+ Celery beat for the daily reconciliation) for notifications and retries |
| Admin mobile app | **Flutter** (Riverpod, Dio), iOS + Android, distributed privately (TestFlight / Play internal testing), never on public stores. Daily operations (quoting, purchases, shipments, pickups) plus back office for super admins (devices, admin users, refunds, settings, pickup points, reports). Push via Firebase Cloud Messaging |
| Customer app | **Flutter** (Riverpod, Dio), iOS + Android. **No web app** — mobile only. Receives SHEIN shares (Android intent; iOS Share Extension still to add in Xcode) |
| Payments | Wave Checkout API |
| Messaging | WhatsApp Cloud API (Meta) directly, or 360dialog — order notifications only |
| Customer login | Ivorian phone number + password (argon2id). No OTP. Forgotten password: admin issues a temporary one, customer must change it |
| Secrets | Doppler (injected at runtime; never committed) |
| Hosting | Railway or Fly.io for the API |

## Domain model

All money is stored as integer XOF (`amount_xof BIGINT`) — XOF has no minor unit.
Foreign prices store the original currency and amount plus the locked rate.

- `customers` — id, display_name, phone_e164 (encrypted) + phone_hash (lookup), locale (`fr` default), created_at
- `admin_users` — id, email, role (`VIEWER` | `OPERATOR` | `SUPER_ADMIN`), totp_secret (encrypted), last_login_at
- `admin_devices` — id, admin_user_id, platform, push_token, device_public_key, approved_by, approved_at, revoked_at, last_seen_at
- `orders` — id, public_ref (e.g. `FLR-7K3Q9`, created at order creation), customer_id, source_cart_url (`https://onelink.shein.com/…` exactly as shared; never fetched by the server), status, pickup_point_id, quote_expires_at, total_xof, created_at
- `order_items` — entered by the admin from the shared cart (or from product links): id, order_id, source (`SHEIN`, …), source_url, source_product_id, title, size, color, qty, customer_note, source_price, source_currency, fx_rate, unit_price_xof, item_status (`OK` | `CANCELLED_BY_STORE` | `MISSING`)
- `order_attachments` — id, order_id, kind (`CART_SCREENSHOT`), storage_key, uploaded_at (private bucket, signed URLs only)
- `quotes` — id, order_id, version (1, 2, …; unique per order), status (`DRAFT` | `SENT` | `ACCEPTED` | `CHANGE_REQUESTED` | `EXPIRED` | `SUPERSEDED`), items_xof, freight_xof, customs_xof, fee_xof (entered by admin), total_xof (computed server-side), fx_rate, admin_note, expires_at, created_by, sent_at, answered_at. Sent quotes are immutable; any change = new version, previous one `SUPERSEDED`
- `quote_lines` — quote_id, order_item_id, title, size, color, qty, unit_price_xof (snapshot of what the customer saw)
- `quote_change_requests` — id, quote_id, new_cart_url, removed_item_ids, line_changes (JSON: size/colour/qty), note, created_at
- `payments` — id, order_id, quote_id (the accepted quote), provider (`WAVE`), checkout_session_id, provider_txn_id, amount_xof, status, idempotency_key (unique), created_at, confirmed_at
- `refunds` — id, payment_id, amount_xof, reason, status, created_by
- `store_purchases` — id, order_id, store (`SHEIN`), store_order_ref, paid_amount, currency, purchased_by, purchased_at
- `shipments` — id, forwarder, tracking_ref, weight_kg, cost_xof, status (`OPEN` | `IN_TRANSIT` | `ARRIVED`), departed_at, arrived_at
- `shipment_orders` — shipment_id, order_id
- `pickup_points` — id, name, address, commune, opening_hours, active
- `pickup_codes` — order_id, code_hash, used_at
- `webhook_events` — id, provider, event_id (unique per provider), type, received_at, processed_at
- `audit_log` — id, actor_type, actor_id, action, entity, entity_id, before, after, ip, created_at (append-only)
- `order_status_history` — order_id, from_status, to_status, actor, created_at

## Roadmap

1. **Validate:** customers send their SHEIN cart link on WhatsApp Business; Wave payment links; spreadsheet. 30–50 real orders. Record quoting time and wrong-size rate; build the unit-economics model.
2. **Built (Oct 2026):** FastAPI backend, admin Flutter app, customer Flutter app. See README.md for how to run them.
3. **Before launch:** Wave Business API access, Meta WhatsApp templates approved in `fr`, Firebase project, iOS Share Extension, store/TestFlight distribution, production hosting + Doppler.

## Compliance

- Ivorian data-protection law 2013-450 (ARTCI): declare processing, provide data export/deletion, keep PII minimal.
- Registered company (CEPICI), invoices, and customs/VAT handling on imported goods.
