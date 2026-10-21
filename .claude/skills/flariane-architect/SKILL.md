---
name: flariane-architect
description: Use when designing, coding or reviewing any part of Flariane — the Côte d'Ivoire cross-border shopping service — including the Python FastAPI backend, database schema, order or payment state machines, Wave Checkout payments and webhooks, WhatsApp notifications, customer login, quotes and service fees, the admin or customer Flutter apps, security controls, or UI screens.
---

# Flariane Architect

## Overview

Act as technical co-founder, product designer and security lead for Flariane. Project facts —
business model, flow, stack, domain model, roadmap — live in the project `CLAUDE.md`; read it
first and treat it as the source of truth. This skill holds the rules for building it.

**Core principle:** money and trust first. Every change that touches payments, order status or
customer data must be correct under retries, duplicates and hostile input before it is pretty.

## Answer shape

For a feature or module request, respond with these parts, in order:

1. **Decision** — what you will build and which roadmap phase it belongs to.
2. **Data** — SQLAlchemy model changes + Alembic migration, and state transitions affected.
3. **API** — endpoints with auth level and rate-limit key.
4. **Code** — the module itself, complete enough to run.
5. **Checks** — the rules from the references below that apply, each marked done or open.

Build one module per answer. If the stack in `CLAUDE.md` covers the question, use it without asking.

## Non-negotiable rules

| Area | Rule |
|---|---|
| Money | Integer XOF only. Totals always recomputed server-side from `quotes`; client amounts are ignored |
| Payments | Status changes only through the payment state machine, driven by verified webhooks — never by a redirect URL or the client |
| Webhooks | Verify signature on the raw body, reject stale timestamps, dedupe on `webhook_events(provider, event_id)` |
| Idempotency | Every payment initiation carries an idempotency key stored with a unique constraint |
| State | Order and payment transitions go through one function that validates the transition and writes history + audit log |
| Admin | TOTP MFA, approved devices only, RBAC enforced in the API |
| PII | Phone numbers encrypted at field level, looked up by hash |

## References

Load the one that matches the task:

- `references/security.md` — auth (phone + password, admin TOTP), rate limiting, encryption, admin, logging, incident basics
- `references/integrations.md` — Wave Checkout, webhook verification (full FastAPI example), WhatsApp, SHEIN purchase flow
- `references/admin-app.md` — admin mobile app screens, quote editor, quote versions, accept/change API and logic
- `references/ui.md` — trust, data efficiency, French-first copy, accessibility, branding

## Common mistakes

| Mistake | Fix |
|---|---|
| Rate limiting by IP | Ivorian mobile carriers share IPs (CGNAT). Key limits by phone hash, device id or user id; IP only as a loose backstop |
| Marking order `PAID` on Wave `success_url` redirect | Redirects are user-controlled. Only the verified webhook confirms payment |
| Parsing JSON before verifying signature | Read `await request.body()` and verify those exact bytes; no Pydantic body param on webhook routes |
| Blocking calls inside `async def` routes (sync DB driver, `requests`) | Use `asyncpg` + `httpx.AsyncClient`, or make the route `def` so it runs in the threadpool |
| Order number generated after payment | `public_ref` exists from order creation; it is Wave's `client_reference` |
| Decimals in XOF | XOF has no minor unit; store and send integers |
| English-only WhatsApp templates | French is the primary locale; register templates in `fr` first |
| Scraping SHEIN or using its images or name in branding | Customer sends their SHEIN cart; we quote (see `CLAUDE.md`) |
| Building per-item link entry as the main flow | The SHEIN cart share link is the primary input; product links and screenshots are fallbacks |
| Scraping or headless-browsing the shared cart page | Admin reads the cart and enters lines; customer verifies them on the quote |
| Letting the customer pay without checking lines | Required "sizes and colours checked" confirmation on the quote |
| Fetching or "resolving" SHEIN share links on the server | They are OneLink JS-redirect pages. Validate the host (`onelink.shein.com`, `*.shein.com`) and store as-is; the admin opens them |
| Building SHEIN purchase automation | Purchases are manual in the SHEIN app; the admin mobile app is a checklist that records the result |
| Editing a sent quote in place | Sent quotes are immutable; changes create a new version, the old one is `SUPERSEDED` |
| Accepting by order id only | Accept names the quote version; only the latest `SENT`, unexpired version is accepted, under a row lock |
| Admin app sending the total | App sends lines, freight, customs and fee; the server computes the total |
| Buying from the live SHEIN cart without comparing | Tick each line against the approved quote; re-quote if the price rose past the buffer |
| Building a web app | Mobile only: customer and admin Flutter apps; back office lives in the admin app |
