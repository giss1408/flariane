# UI and UX rules

Applies to the customer and admin Flutter apps and customer-facing messages.
Admin back-office screens use plain Material lists for speed.

## Trust

- One primary action per screen ("Payer avec Wave"), high contrast, min 48dp tall.
  Secondary actions outlined or text-only.
- Always show the full price breakdown before payment: articles, transport, douane, frais de
  service, total in FCFA, and the quote expiry.
- Every action gets immediate feedback: skeletons while loading, clear success and error
  states. Never leave the customer unsure whether a payment or submission worked.
- After Wave redirects back: "Nous confirmons votre paiement…" with a spinner, polling the API,
  then success or a clear "Pas encore confirmé — réessayer / contacter le support" after 2 minutes.
- Order tracking is a vertical stepper: Devis → Payé → Acheté → En route → Arrivé →
  Prêt au retrait → Retiré. Current step bold and coloured, past steps checked, future greyed.
  Show the expected date range on the current step.
- A visible WhatsApp support button on every order screen.

## Sending a SHEIN cart

- Home screen primary action: "Envoyer mon panier SHEIN". Below it, a 3-step illustrated
  guide: remplir le panier dans SHEIN → Panier → Partager → Flariane (ou copier le lien).
- The send screen has one field: the cart link, auto-filled when shared in, with a "Coller"
  button. Secondary text actions: "Ajouter des liens d'articles", "Ajouter une capture du panier".
- Before sending, remind once: "Vérifiez tailles et couleurs dans votre panier SHEIN."
- After submit: "Devis en préparation — vous recevrez un message WhatsApp" with the expected
  delay (e.g. under 2 hours during opening hours).
- Quote screen: version label ("Devis n°2"), expiry ("valable jusqu'au 24/10 à 18h"), one card
  per line (title, size, colour, qty, price in FCFA), then the cost breakdown (articles,
  transport, douane, **frais de service**, total), then a required checkbox "Tailles et
  couleurs vérifiées" before the primary button "Accepter et payer avec Wave" is enabled.
  Secondary outlined button: "Modifier ma commande".
- "Modifier ma commande" opens a form: replace the cart link, remove lines, fix size/colour/qty
  per line, free note. Confirmation: "Demande envoyée — vous recevrez un nouveau devis."
- If the quote changed or expired while the screen was open (API `409`), reload and say so:
  "Le devis a été mis à jour" — never charge for an outdated version.

## Admin mobile app

- French UI, built for one-hand use on a phone; Material 3 components, same palette.
- Quote editor: numeric keypad for amounts, FCFA formatting as you type, sticky footer with the
  total and margin, "Envoyer le devis" as the only primary button. Margin below the minimum
  shows an amber warning and requires a confirm tap.
- Cart link button is large and labelled "Ouvrir dans SHEIN".
- Lists show `public_ref`, age ("il y a 3 h") and status chip; overdue quote requests
  (> 2 h in opening hours) highlighted.

## Data efficiency

- Images: thumbnails only, WebP, lazy-loaded, blurhash placeholders; cache aggressively
  (`cached_network_image`).
- Cache the customer's orders for offline viewing. Queue non-payment actions while offline;
  never queue payments.

## Language and copy

- French is the primary locale, English secondary. All strings externalised
  (`intl`/ARB).
- Prices formatted `25 000 FCFA` (space thousands separator, no decimals).
- Phone input defaults to +225 and validates 10-digit Ivorian numbers.
- Plain, warm, short sentences. No pressure tactics or fake countdowns.

## Accessibility

- WCAG AA contrast (4.5:1 for body text, 3:1 for large text and icons).
- Touch targets ≥ 48×48dp. Body text ≥ 14sp/16px; respect system font scaling.
- Status is never conveyed by colour alone — pair it with an icon or label.

## Branding

- Trustworthy, calm palette: deep teal or royal blue primary, white backgrounds, dark grey
  text. Distinct from Wave's light blue so the Wave button reads as Wave's.
- No discount-store look: no red price bursts, no flashing badges.
- Font: Inter (or system sans-serif). Consistent line height (1.4–1.5 body).
- No SHEIN logos, names or product photography in branding or store listings.
