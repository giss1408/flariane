# Admin mobile app and quotes

Flutter app (Riverpod, Dio) for the admin's daily work on the same phone as the SHEIN app.
Private distribution only (TestFlight / Play internal testing). Talks to `/admin/*` API routes.

## Screens

| Screen | Purpose |
|---|---|
| **Inbox** | Tabs: À chiffrer (`QUOTE_REQUESTED`, incl. change requests), Devis envoyés, À acheter (`PAID`), Expéditions, Retraits. Oldest first, badge counts |
| **Order** | Customer (masked phone), cart link button (opens SHEIN app), screenshots, quote history (v1, v2… with status), change-request note highlighted |
| **Quote editor** | Item lines + freight + customs + **service fee** + note → live total → Send |
| **Purchase checklist** | Accepted quote lines to tick while buying in SHEIN; record SHEIN order ref + amount paid |
| **Shipments / Pickups** | Add orders to the weekly shipment, mark arrived, scan or type pickup code |

Push notifications (FCM): new quote request, change request, quote accepted, payment confirmed.
Notification text never contains customer names, phone numbers or amounts — only `public_ref`.

## Quote editor rules

- Item lines: title, size, colour, qty, SHEIN price + currency. On a change request, start
  from the previous version's lines with the requested changes shown as a diff to apply.
- Freight and customs are pre-filled from settings (rates per kg / per category) and editable.
- **Service fee is typed by the admin for each order** (integer FCFA). Show alongside it:
  the margin it produces and the minimum fee from settings. Below the minimum → warning plus
  explicit confirm; never block.
- The app shows a preview total, but the server recomputes every amount on send and returns
  the authoritative total. The app never sends a total.
- Draft autosaves to the server (`DRAFT` quote) so a lost connection loses nothing.
- Send → quote `SENT`, immutable from then on. Fixing a sent quote = new version.

## Quote lifecycle

```
DRAFT → SENT → ACCEPTED            (customer accepts → payment)
             → CHANGE_REQUESTED    (customer asks for changes → admin drafts next version)
             → EXPIRED             (expires_at passed, Celery beat job)
             → SUPERSEDED          (admin sent a newer version)
```

Only the **latest SENT** version of an order can be accepted.

## API

Admin (`require_role("OPERATOR")`, approved device):

| Method | Path | Notes |
|---|---|---|
| GET | `/admin/orders?tab=…` | Inbox lists |
| GET | `/admin/orders/{id}` | Order, items, attachments (signed URLs), quote history |
| PUT | `/admin/orders/{id}/quote-draft` | Lines, freight, customs, fee, note → returns server-computed totals |
| POST | `/admin/orders/{id}/quotes/{version}/send` | Freezes the draft, notifies customer |

Customer:

| Method | Path | Notes |
|---|---|---|
| GET | `/orders/{ref}/quote` | Latest quote with lines and breakdown |
| POST | `/orders/{ref}/quotes/{version}/accept` | Body `{ "sizes_confirmed": true }` → returns `wave_launch_url` |
| POST | `/orders/{ref}/quotes/{version}/change-request` | New cart link, removed lines, line changes, note |

## Accepting a quote (critical logic)

Accept and payment creation happen in one transaction with a row lock, so a double tap, a
stale screen, or a race with the admin sending a new version cannot produce a wrong charge.

```python
# app/quotes/service.py
async def accept_quote(db: AsyncSession, customer_id: int, ref: str, version: int) -> Payment:
    async with db.begin():
        order = await db.scalar(
            select(Order).where(Order.public_ref == ref, Order.customer_id == customer_id)
            .with_for_update()
        )
        if order is None:
            raise NotFound()
        quote = await db.scalar(
            select(Quote).where(Quote.order_id == order.id)
            .order_by(Quote.version.desc()).limit(1)
        )
        # Same quote already accepted (double tap): return the existing payment.
        if quote and quote.version == version and quote.status == QuoteStatus.ACCEPTED:
            return await db.scalar(select(Payment).where(Payment.quote_id == quote.id))
        if quote is None or quote.version != version or quote.status != QuoteStatus.SENT:
            raise Conflict("quote_outdated")  # app reloads and shows the latest version
        if quote.expires_at <= utcnow():
            raise Conflict("quote_expired")

        quote.status, quote.answered_at = QuoteStatus.ACCEPTED, utcnow()
        await transition_order(db, order, OrderStatus.AWAITING_PAYMENT, actor=("customer", customer_id))
        payment = Payment(
            order_id=order.id, quote_id=quote.id, provider="WAVE",
            amount_xof=quote.total_xof,            # from the frozen quote, never the request
            idempotency_key=f"quote-{quote.id}",   # unique: one checkout per accepted quote
            status=PaymentStatus.INITIATED,
        )
        db.add(payment)
    # Outside the transaction: create the Wave checkout session with payment.idempotency_key.
    return payment
```

Change request: same lock; requires latest version in `SENT`; sets `CHANGE_REQUESTED`, stores
the request, moves the order to `QUOTE_REQUESTED`, pushes the admin. An `ACCEPTED` quote whose
payment is still pending can be cancelled by the customer (payment → `EXPIRED`) before asking
for changes; a `PAID` order cannot be changed in the app — support handles it.
