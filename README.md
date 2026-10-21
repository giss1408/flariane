# Flariane

| Folder | What |
|---|---|
| `backend/` | FastAPI API, Postgres, Celery tasks (72 tests) |
| `admin_app/` | Flutter admin app: quoting, purchases, shipments, pickups, back office |
| `customer_app/` | Flutter customer app: send SHEIN cart, accept/modify quote, pay with Wave, track |

## Run locally

```bash
docker compose up -d                      # Postgres :5433, Redis :6380
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
cp .env.example .env && .venv/bin/python -m app.cli gen-keys >> .env   # then remove the empty key lines
.venv/bin/alembic upgrade head
.venv/bin/python -m app.cli create-admin --email you@x.ci --name "Vous"   # prints the TOTP URI
.venv/bin/python -m app.cli seed-pickup-points
.venv/bin/uvicorn app.main:app --reload --port 8000
.venv/bin/pytest                          # tests use a separate flariane_test database
```

First admin device: log in from the admin app → it shows "en attente" → `python -m app.cli list-devices`
then `python -m app.cli approve-device --device-id N`. Later devices are approved in the app (Compte → Appareils).

Apps (Android emulator reaches the host at 10.0.2.2, the default):

```bash
cd admin_app && flutter run              # or --dart-define=API_BASE_URL=https://api.flariane.ci
cd customer_app && flutter run
```

In dev, Wave is simulated (`FLR_WAVE_MODE=fake`): "Payer avec Wave" opens a local page that sends a signed
webhook. WhatsApp messages and push notifications are logged instead of sent.

## Before production

- Wave Business API key + webhook secret (`FLR_WAVE_MODE=live`); check field names against docs.wave.com.
- Meta WhatsApp Cloud API: register templates in `fr` (`quote_ready`, `payment_received`,
  `order_ready_pickup`, `item_cancelled`, `refund_completed`); `FLR_WHATSAPP_MODE=live`.
- Firebase: `flutterfire configure` in `admin_app/` for push; `FLR_PUSH_MODE=live` + service account.
- iOS: needs full Xcode. Customer app needs a Share Extension target for "Partager → Flariane" on iPhone.
- Hosting: API on Railway/Fly (`uvicorn --proxy-headers`), Celery worker + beat, managed Postgres/Redis,
  secrets in Doppler, S3/R2 for screenshots (`FLR_STORAGE_MODE=s3`).

## Deploy the backend for testing (free: Render + Neon)

1. **Neon** (neon.tech, free): create a project in region **AWS Europe Central (Frankfurt)**, then
   Connect → copy the connection string. Prefer the **direct** (non-pooler) one; pooled also works.
2. **Render** → New → **Blueprint** → this repo. [`render.yaml`](render.yaml) creates one **free** web
   service `flariane-api`. Paste the Neon string into `FLR_DATABASE_URL` when asked.
3. If the URL isn't `https://flariane-api.onrender.com`, update `FLR_API_BASE_URL`.
4. Render shell: `python -m app.cli seed-pickup-points` (and `create-admin` for the admin app).
5. Apps: `flutter run --dart-define=API_BASE_URL=https://flariane-api.onrender.com --dart-define=DEV_BYPASS_AUTH=true`

Free-plan trade-offs: the API sleeps after ~15 min idle (first request ~1 min), no worker (tasks and
periodic jobs run inside the API while awake), uploaded screenshots are lost on restart.
Migrations run at every start. The encryption/token keys are generated once by Render — never change them.

**Production** uses [`render.production.yaml`](render.production.yaml): paid API + Celery worker,
Render Postgres + Key Value. Before real customers set `FLR_ENV=prod` (disables test routes),
live Wave/WhatsApp, and `FLR_STORAGE_MODE=s3`.
