"""Messages the admin sends from their own WhatsApp (wa.me links), written server-side so
wording stays consistent. Customers are addressed with "tu"."""

from urllib.parse import quote as urlquote

from app.models import Customer, Order, PickupPoint, Quote
from app.services.notify import fcfa, first_name, short_datetime

KINDS = ("quote", "payment", "pickup", "wrong_link")


def store_name(order: Order) -> str:
    return "Temu" if order.store == "TEMU" else "SHEIN"


def text_for(kind: str, customer: Customer, order: Order, quote: Quote | None, point: PickupPoint | None, code: str | None) -> str:
    name = first_name(customer)
    if kind == "quote":
        assert quote is not None
        validity = f" Valable jusqu’au {short_datetime(quote.expires_at)}." if quote.expires_at else ""
        return (
            f"Bonjour {name} 👋 Ton devis Flariane pour la commande {order.public_ref} est prêt : "
            f"*{fcfa(quote.total_xof)} FCFA* (panier {store_name(order)} + transport).{validity}\n\n"
            "Ouvre l’app Flariane pour vérifier la capture de ton panier et payer avec Wave. "
            "Les prix affichés dans l’app à Abidjan peuvent différer de ceux au moment de notre commande."
        )
    if kind == "payment":
        return (
            f"Merci {name} ! Paiement reçu pour ta commande {order.public_ref} ✅ "
            f"On passe ta commande {store_name(order)}. Tu peux suivre son avancement dans l’app Flariane."
        )
    if kind == "wrong_link":
        return (
            f"Bonjour {name} 👋 Le lien envoyé pour ta commande {order.public_ref} ne fonctionne pas "
            f"(ce n’est pas un panier {store_name(order)} valide). On a supprimé cette commande.\n\n"
            "On achète uniquement sur la boutique européenne (prix en €) : si ton app SHEIN ou Temu est sur les USA ou le "
            "Royaume-Uni, passe-la sur la France ou l’Allemagne et refais ton panier.\n\n"
            "Ouvre ton panier dans l’app, touche Partager, puis envoie-le à Flariane pour recevoir ton devis."
        )
    assert point is not None and code is not None
    return (
        f"Bonjour {name} 🎉 Ta commande {order.public_ref} est arrivée à Abidjan !\n\n"
        f"Retrait : {point.name}, {point.address}\nHoraires : {point.opening_hours}\n"
        f"Ton code de retrait : *{code}*\n\nPrésente ce code au retrait."
    )


def temp_password_text(customer: Customer, temp: str) -> str:
    return (
        f"Bonjour {first_name(customer)} 👋 Voici ton mot de passe temporaire Flariane : *{temp}*\n\n"
        "Connecte-toi dans les 24 h avec ce mot de passe : l’app te demandera d’en choisir un nouveau. "
        "Si tu n’as pas fait cette demande, réponds-nous ici."
    )


def wa_link(phone_e164: str, text: str) -> str:
    return f"https://wa.me/{phone_e164.lstrip('+')}?text={urlquote(text)}"
