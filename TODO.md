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
      (`/setup/reset-admin` can take over the super admin account). The API now logs a warning at start-up
      in prod while it is set.
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

- [x] New proofs are stored through the `storage` layer (`payments.proof_key`); the admin proof endpoint streams
      them from storage (and still reads old blobs).
- [ ] **Configure object storage (Cloudflare R2 or S3)** on the test and production services: fill
      `FLR_S3_BUCKET`, `FLR_S3_ENDPOINT_URL`, `FLR_S3_ACCESS_KEY`, `FLR_S3_SECRET_KEY` in the Render dashboard, then
      set `FLR_STORAGE_MODE=s3`. Until then cart screenshots are lost at every restart (seen on the test server:
      old orders show "Image indisponible"). Payment proofs stay in the database while storage is local, and the API
      logs an error at start-up in prod.
- [ ] After S3 is on: run `python -m app.cli migrate-proofs` once (Render shell); it refuses to run without S3.
- [ ] Then add a migration that drops `payments.proof_image` and the fallback in `admin_orders.payment_proof`.

## 7. Push instead of polling + ETags

Goal: less battery, data and server load; the apps refresh when something actually changed.

- [ ] Customer app: replace the 20 s `AutoRefresh` timer with a push (FCM) that triggers a refresh; keep a slow
      fallback (e.g. 2 min) and the refresh on app resume.
- [ ] Admin app: same for the 60 s attention timer in `core/attention.dart`.
- [ ] Backend: `ETag` / `If-None-Match` on `GET /orders`, `GET /orders/{ref}` and the admin inbox, so an unchanged
      poll answers `304` with no body (today every response is `Cache-Control: no-store`).
- [ ] Add keyset pagination to the admin inbox (limit 200) and customer list (limit 100). The composite index on
      `(status, status_changed_at)` is done.
- [x] Admin app images use the disk-cached `CachedImage` (same widget as the customer app).

## 8. Turn on error tracking (Sentry)

The code is in place in the API and both apps, and does nothing until a DSN is set.

- [ ] Create a Sentry project (or three: API, customer app, admin app) and copy the DSNs.
- [ ] API: set `FLR_SENTRY_DSN` in the Render environment.
- [ ] Apps: add `--dart-define=SENTRY_DSN="$SENTRY_DSN"` to the release builds in `codemagic.yaml` (a Codemagic
      secret variable), for both apps.
- [ ] Mention Sentry in the privacy policy (crash reports, no personal data sent: no request bodies, no IP/user,
      no screenshots) for ARTCI.
- [ ] Optional: upload Dart debug symbols so stack traces are readable (`sentry_dart_plugin`).

## 9. Process flow improvements (from the end-to-end run, Nov 2026)

Ordered by value. Details and reasoning were given in the chat; tick when done.

- [x] **Departure dead end:** "Ajouter à une expédition" says "Aucun départ prévu" when the next-departure date already
      has a shipment that left or arrived. Offer "Créer le prochain départ" right in that sheet (date picker), and
      suggest a new date when a shipment is marked departed.
- [ ] **Messages to send by hand:** the quote, the arrival + pickup code and the payment confirmation each open WhatsApp
      and nothing records whether the admin really sent it. Add a "messages à envoyer" list with "marqué comme envoyé"
      until the WhatsApp Cloud API templates are approved; then send automatically.
- [x] **Batch "prête au retrait":** after a shipment arrives, every order needs its own pickup point choice and message.
      Add one action per shipment / pickup point.
- [x] **Pickup code in the customer app:** today it exists only in WhatsApp, so a lost code means "Renvoyer le code",
      which invalidates the old one. Show it to the signed-in owner on the order screen.
- [ ] **Payment check:** the admin matches the Wave screenshot by eye. Flag amount/reference mismatches, and reconcile with
      the Wave Business API later.
- [ ] **Freshness:** orders update after up to 20 s on the customer phone; see item 7 (push + ETag).

## 10. Admin push alerts not arriving (test server, Nov 2026)

The API creates the push correctly (tested), so the cause is on the server's Firebase side. New super-admin screen
**Compte › Notifications** shows the mode, whether the service-account key is set, the devices' push tokens, a test
button, and the last attempts with Firebase's error.

- [ ] Deploy, open that screen on the admin phone, tap "Envoyer un test" and read the error.
- [ ] Most likely: `FLR_FCM_SERVICE_ACCOUNT_JSON` missing/invalid on the test service, or the Firebase Cloud Messaging API
      not enabled for the `flariane` project / the service account lacking the "Firebase Cloud Messaging API Admin" role.
- [ ] Remember: with the admin app in the foreground the alert is a snackbar, not a system notification.

## 11. Customer app ease of use (next)

Done: first-order steps with "Ouvrir SHEIN / Temu", copied-link suggestion on the new-order screen, Wave shortcut +
amount copy on the payment screen.

- [ ] Verify the shortcut package ids on a phone with the apps installed (`com.zzkko`, `com.einnovation.temu`,
      `com.wave.personal`) and add Orange Money / Moov Money ids if wanted.
- [x] Quote screen shows "Total à payer" at the top. Still open: fold "J'ai vérifié mon panier" into the accept confirmation.
- [x] Order list shows the next step in plain words ("À toi : paie et envoie la capture"). Still open: group active / finished.
- [ ] Ask for the Abidjan address once, in context, before the first quote.
- [x] "tu" everywhere in the customer app (and gender-neutral wording).
- [x] "Réessayer" on every failed load (already the case).
- [ ] Customer push notifications instead of 20 s polling (item 7).
