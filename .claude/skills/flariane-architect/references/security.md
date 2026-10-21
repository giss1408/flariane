# Security rules

Priority tags: **[P1]** required before taking real money, **[P2]** before public launch,
**[P3]** once there is revenue and a team.

## Authentication

- **[P1]** Customer login = Ivorian mobile number + password, hashed with argon2id. No OTP.
  Minimum 8 characters; trivial digit passwords refused. Unknown numbers get the same error and
  timing as wrong passwords.
- **[P1]** 5 failed logins per phone per 15 min, then locked (keyed by phone hash, not IP).
- **[P1]** Forgotten password: an OPERATOR issues a one-time temporary password (after checking the
  request comes from the customer's WhatsApp number); all sessions are revoked and the app forces
  a new password at next login. Every reset is audit-logged.
- **[P1]** Access token (JWT) 15 min. Refresh token opaque, stored hashed server-side, rotated on
  every use; reuse of an old refresh token revokes the whole session family.
- **[P1]** Refresh token only in `flutter_secure_storage` (Keychain/Keystore); access token in memory.
- **[P2]** Flag risky patterns: new device + first payment above usual amount, many phones per
  device, many devices per phone.

## Payments and integrity

- **[P1]** Webhook signature verification, timestamp tolerance (5 min) and event dedupe — see
  `integrations.md`.
- **[P1]** Payment state machine: `INITIATED → PENDING → SUCCEEDED | FAILED | EXPIRED`;
  `SUCCEEDED → REFUNDED`. Any other transition throws and is logged.
- **[P1]** Webhook amount and currency must equal the stored payment. Mismatch → payment held
  for review, alert raised, order not advanced.
- **[P1]** Daily reconciliation job: compare Wave transactions with `payments`; report
  differences to the admin.

## Rate limiting

Redis-backed moving window via the `limits` library, applied as FastAPI dependencies that run
after authentication so they can key on the account (see `app/ratelimit.py`).

| Caller | Key | Limit |
|---|---|---|
| Customer login failures | phone hash | 5 / 15 min |
| Unauthenticated (other) | IP | 120/min (loose: CGNAT shares IPs) |
| Customer | user id | 60/min |
| Admin | admin id | 300/min |
| Webhooks | not limited by count; protected by signature | — |

## Data protection

- **[P1]** TLS everywhere, HSTS, no plain-HTTP endpoints.
- **[P1]** Field-level encryption (AES-256-GCM, key from Doppler) for phone numbers and pickup
  names; store an HMAC-SHA256 `phone_hash` for lookups.
- **[P1]** Validate every input with Pydantic v2 models using
  `model_config = ConfigDict(extra="forbid")`; separate request and response models so
  internal fields never leak. Database access through SQLAlchemy 2.0 only; no f-string or
  concatenated SQL (`text()` only with bound parameters).
- **[P1]** Security headers middleware (HSTS, `X-Content-Type-Options`, `Referrer-Policy`,
  `X-Frame-Options: DENY`); `CORSMiddleware` with an explicit origin list, never `*`.
  Disable `/docs` and `/openapi.json` in production.
- **[P1]** Libraries: `PyJWT` for tokens, `pyotp` for TOTP, `cryptography` (`AESGCM`) for
  field-level encryption, `argon2-cffi` for any password-like secret.
- **[P2]** Data export and deletion endpoint (ARTCI). Deletion anonymises the customer but keeps
  financial records required for accounting.
- **[P3]** Certificate pinning in Flutter only with SPKI pins including a backup key, and a
  remote kill switch.

## Secrets

- **[P1]** No secrets in the repo, Docker images or client bundles. Doppler injects them at
  runtime. `.env` files are local-dev only and git-ignored.
- **[P2]** Rotate Wave, WhatsApp and encryption keys on staff change or suspected leak, and at
  least yearly.

## Admin mobile app

- **[P1]** TOTP MFA for every admin account. No exceptions.
- **[P1]** Mobile app login = email + password + TOTP, then **device approval**: the app
  creates a key pair in the Keychain/Keystore, registers the public key in `admin_devices`, and
  a `SUPER_ADMIN` approves it (the first device with `python -m app.cli approve-device`). Refresh
  tokens are bound to the device; a revoked device loses access at its next request.
- **[P1]** Biometric/PIN unlock (`local_auth`) when the app returns after 5 min in background;
  full re-login (with TOTP) every 12 h. Tokens only in `flutter_secure_storage`.
- **[P1]** `/admin/*` routes accept only admin tokens; customer tokens are rejected there, and
  admin tokens are rejected on customer routes.
- **[P2]** Mask customer phone numbers in the app (`+225 07 •• •• 45`); reveal on tap, logged.
  Block screenshots on Android order screens (`FLAG_SECURE`).
- **[P3]** App attestation (Play Integrity / App Attest) on admin login.
- **[P1]** RBAC checked in the API with a `require_role(...)` dependency on every admin route
  (or on the admin router), not only hidden in the UI:
  `VIEWER` read-only; `OPERATOR` quotes, purchases, shipments, pickups; `SUPER_ADMIN` refunds,
  admin users, settings.
- **[P2]** Refunds above a threshold need a second admin's approval.

## Logging and monitoring

- **[P1]** Append-only `audit_log` for every payment event, status change, refund, admin action
  and login. Never log passwords, tokens or full phone numbers.
- **[P1]** Alerts (email/Telegram/WhatsApp to the admin) on: webhook signature failures,
  payment amount mismatch, a phone hitting the login lock repeatedly, refund issued.
- **[P2]** Sentry for errors, uptime check on the webhook endpoint.
- **[P3]** External OWASP-based review before major launches; fix Critical findings before release.
