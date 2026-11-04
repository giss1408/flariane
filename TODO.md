# TODO

Security hardening still to do (from the backend review). Done already: registration rate limits,
`FLR_TRUSTED_PROXY_HOPS` proxy handling, Argon2 off the event loop, idempotency keys on order creation and
payment declaration.

## 1. App attestation (Firebase App Check)

Goal: the backend only serves requests that come from the genuine, unmodified Flariane apps.

- [ ] Create the Firebase project (also needed for FCM push) and register the customer and admin apps.
- [ ] Enable Play Integrity (Android) and App Attest (iOS) as App Check providers.
- [ ] Flutter, both apps: add `firebase_app_check`, activate it at startup, and add a Dio interceptor that sends
      the token in the `X-Firebase-AppCheck` header.
- [ ] Backend: a dependency that verifies the App Check token (Firebase Admin SDK or the JWKS endpoint) on every
      route except `/webhooks/*`, `/health`, `/files/*` and the public legal pages.
- [ ] Roll out in log-only mode first (a setting such as `FLR_APPCHECK_MODE=off|log|enforce`), then enforce once
      real devices pass.
- [ ] Debug provider for dev builds and CI; decide how test users on side-loaded builds get through.
- [ ] Limits to remember: needs signed builds from Play / TestFlight, and rooted devices can still pass.

## 4. Admin hardening

Goal: a stolen admin password + authenticator code is not enough, and the admin API is not open to the whole internet.

- [ ] Sign admin requests (or the session) with a hardware-backed device key (Android Keystore / iOS Secure
      Enclave). `admin_devices.device_public_key` is already in the model; the backend verifies the signature.
- [ ] Put `/admin/*` and `/setup/*` behind Cloudflare Access, an IP allowlist, or a VPN (e.g. Tailscale), ideally
      on a separate hostname from the customer API.
- [ ] Confirm `FLR_SETUP_TOKEN` is unset in production once the first super admin exists
      (`/setup/reset-admin` can take over the super admin account).
- [ ] If Cloudflare ends up in front of Render, set `FLR_TRUSTED_PROXY_HOPS=2`.

## 5. Certificate pinning

Goal: block man-in-the-middle proxies (Burp, mitmproxy) on the phone.

- [ ] Fix the production domain and the certificate / CA plan first (pinning to a leaf certificate breaks on renewal).
- [ ] Pin the public key (SPKI hash) of the issuing CA or the leaf, with at least one backup pin, in the Dio client of
      both apps (`customer_app/lib/core/api.dart`, and the admin app's API client).
- [ ] Plan rotation: ship the new pin in an app release before the certificate changes.
- [ ] Add a remote kill switch or short pin expiry so a bad pin cannot lock every user out.
- [ ] Test against a proxy with a user-installed CA to confirm requests are refused.

## 6. Move payment proof images out of Postgres

Goal: keep the database small (Neon free tier, backups) and serve proofs like the cart screenshots.

- [ ] Store `Payment.proof_image` through the existing `storage` layer (S3 or local) and keep only the storage key
      and content type on the row.
- [ ] Migration: copy existing blobs to storage, then drop the `proof_image` column.
- [ ] Admin proof endpoint (`admin_orders.py`) returns a short-lived signed URL, or streams from storage.

## 7. Push instead of polling + ETags

Goal: less battery, data and server load; the apps refresh when something actually changed.

- [ ] Customer app: replace the 20 s `AutoRefresh` timer with a push (FCM) that triggers a refresh; keep a slow
      fallback (e.g. 2 min) and the refresh on app resume.
- [ ] Admin app: same for the 60 s attention timer in `core/attention.dart`.
- [ ] Backend: `ETag` / `If-None-Match` on `GET /orders`, `GET /orders/{ref}` and the admin inbox, so an unchanged
      poll answers `304` with no body (today every response is `Cache-Control: no-store`).
- [ ] Add keyset pagination to the admin inbox (limit 200) and customer list (limit 100) with a composite index on
      `(status, status_changed_at)`.
