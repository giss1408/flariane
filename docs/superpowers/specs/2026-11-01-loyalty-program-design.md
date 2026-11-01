# Loyalty program (points, referrals, 10 % service-fee reduction)

Status: draft for review. Date: 2026-11-01. Branch: `feat/loyalty-program`.

## Goal

Customers earn points for ordering and for recommending Flariane, and spend 100 points for a 10 %
reduction on one order's service fee. The customer app shows their points, their referral code and
the history. Success: a customer can see why their balance changed, redeem 100 points on a quote,
and the amount they pay (manual mobile money or Wave) equals the discounted total shown in the app.

## Decided rules

| Event | Credited to | Points | Trigger |
|---|---|---|---|
| Recommended friend's phone is verified | the referrer | +1 | `phone_verified_at` set on the friend |
| Customer's own parcel collected | the customer | +5 | order → `PICKED_UP` |
| Recommended friend's **first** collected parcel | the referrer | +3 | friend's first order → `PICKED_UP` |
| Redemption | the customer | −100 | customer ticks "use 100 pts" when accepting a quote |

- A redemption gives **10 % of the quote's service fee** (`fee_xof`), rounded down to a whole XOF.
  One redemption per order, 100 points each time. Freight, customs and items are never discounted.
- The 3 points for a referred friend apply to that friend's first collected order only.
- The referral link is a **referral code** the friend types, optionally, when registering.
- All numbers are business settings (see Settings), not constants.

Customer-facing wording says "−10 % sur les frais de service", never a generic "10 % de réduction".

## Data model (backend)

`customers` gains:
- `referral_code` — short, unique, unambiguous characters (no 0/O/1/I), e.g. `AWA-7K3Q`. Generated at
  registration; a migration backfills existing customers.
- `referred_by_id` — nullable FK to `customers`, set once at registration, never changed.

New table `loyalty_ledger` (append-only; balance = sum of `points`):

| Column | Notes |
|---|---|
| `id`, `customer_id` | owner of the points |
| `points` | signed integer |
| `kind` | `REFERRAL_SIGNUP`, `ORDER`, `REFERRED_ORDER`, `REDEEM`, `RELEASE` |
| `order_id` | nullable; set for `ORDER`, `REFERRED_ORDER`, `REDEEM`, `RELEASE` |
| `quote_id` | nullable; set for `REDEEM` and `RELEASE` |
| `referred_customer_id` | nullable; set for `REFERRAL_SIGNUP` and `REFERRED_ORDER` |
| `created_at` | |

Idempotency is enforced by unique indexes, so a repeated transition, webhook or retry cannot pay twice:
- one `REFERRAL_SIGNUP` per `referred_customer_id`
- one `ORDER` per `order_id`
- one `REFERRED_ORDER` per `referred_customer_id` (this is also what makes it "first order only")
- one `REDEEM` and at most one `RELEASE` per `quote_id`: a change request produces a new quote on the
  same order, which can be redeemed again (see Redemption)

`quotes` gains `loyalty_points_used` (int, default 0) and `loyalty_discount_xof` (BIGINT, default 0).
`quotes.total_xof` keeps its meaning (items + freight + customs + fee). The amount to pay is
`total_xof − loyalty_discount_xof`, and `payments.amount_xof` is created from that.

## Behaviour

### Registration
`RegisterIn` takes an optional `referral_code`. An unknown code is rejected with a clear error
(`referral_code_invalid`) so a typo can be corrected; the field can be left empty. A code never links a
customer to themselves (the account is new). The link is stored immediately; the +1 is credited later,
when the friend's phone is verified (the admin-sent code flow), so accounts nobody verifies earn nothing.

### Crediting
Inside the existing `PICKED_UP` transition, in the same transaction as the status change:
1. `ORDER +5` for the order's customer.
2. If that customer has `referred_by_id` and no `REFERRED_ORDER` exists for them: `REFERRED_ORDER +3`
   for the referrer.

The `+1` is credited in the phone-verification step, same transaction as setting `phone_verified_at`.
A deactivated or anonymised referrer is not credited.

### Redemption
- Accepting a quote takes `use_points: bool`. Allowed only when the balance is ≥ 100 and the quote has a
  fee > 0; otherwise `loyalty_not_available`.
- The server locks the customer row, re-checks the balance, writes `REDEEM −100`, and sets
  `loyalty_points_used = 100` and `loyalty_discount_xof = floor(fee_xof × 10 / 100)` on the accepted
  quote, then creates the payment for `total_xof − loyalty_discount_xof`.
- Points are returned (`RELEASE +100`, discount cleared) when the order goes back to `QUOTE_REQUESTED`
  (change request), the quote expires, or the order is cancelled before payment (including the automatic
  unpaid cancellation). The customer can redeem again on the next quote.
- After the order is `PAID`, the points are spent for good. A later refund does not return them.
- Accepting the same quote twice (double tap) must not redeem twice: the existing accepted-quote path
  already hands back the existing payment, and the redemption is part of that same transaction.

### Settings
Added to `DEFAULTS` in `services/settings.py` and editable by a SUPER_ADMIN like the other settings:
`loyalty_points_per_order` = 5, `loyalty_points_referral_signup` = 1, `loyalty_points_referred_order` = 3,
`loyalty_redeem_points` = 100, `loyalty_discount_percent_of_fee` = 10. A change applies to points earned
or redeemed afterwards; the ledger keeps what was actually credited.

## API

- `GET /me/loyalty` → `{ balance, referral_code, redeem_points, discount_percent, history: [{kind,
  points, created_at, order_ref?, friend_name?}] }`. The history shows a friend's display name only, never
  their phone number.
- Quote acceptance endpoint: `use_points` added to the request.
- Order/quote responses to the customer include `loyalty_points_used`, `loyalty_discount_xof` and the
  payable amount; the admin order detail shows the same lines.
- Admin settings endpoint: the five loyalty values.

## Customer app

- **Mes points** screen (from the Account area): balance, progress toward 100, referral code with a
  WhatsApp Share button, history list. Texts in French.
- **Quote review:** when the balance is ≥ 100, a tick box "Utiliser 100 pts : −X FCFA sur les frais de
  service". The total and the amount to pay update immediately.
- **Registration:** optional field "Code de parrainage".

## Admin app

Order and quote detail show "Points utilisés : −X FCFA" and the amount to pay, so what a customer pays
(Wave or manual mobile money, where the admin confirms the amount) reconciles with the quote. The offers
screen is unchanged. The loyalty values are edited in the existing settings screen.

## Out of scope

Points expiry, tiers, redeeming more than 100 points at once, points for reviews or shares, admin manual
point adjustments (a follow-up if needed), shareable deep links, push notifications for points earned.

## Testing

Backend (pytest):
- Crediting: `PICKED_UP` adds +5; a second transition or replay adds nothing; a referred friend's first
  collected order adds +3 to the referrer, the second adds nothing for the referrer.
- `+1` credited on phone verification only, once; an invalid referral code is rejected.
- Redemption: balance < 100 rejected; discount = floor(10 % of fee); payment amount = total − discount;
  two concurrent acceptances redeem once; release on change request, expiry and cancellation; no release
  after `PAID`.
- Settings: changed values apply to later events only.
- Migration: existing customers get unique codes.

Customer app (widget tests): points screen renders balance, code and history; the tick box appears only at
≥ 100 points and updates the total; the registration field sends the code and shows the error for an
invalid one.

Admin app (widget test): order detail shows the loyalty line and payable amount.
