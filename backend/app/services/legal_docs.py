"""The legal texts, written once: the app reads them as JSON and the stores' web links as HTML.

Plain French ("tu"), each document opens with an "En bref" summary. Numbers that the team can change in the
settings (quote validity, payment deadline, fee minimum) are read from there, never hard-coded in the text.
Bump `customer_auth.CONSENT_VERSION` when the terms or the privacy policy change in substance."""

from dataclasses import asdict, dataclass, field
from typing import Any

from app.config import Settings

UPDATED = "2026-11-06"


@dataclass
class Section:
    heading: str
    paragraphs: list[str] = field(default_factory=list)
    bullets: list[str] = field(default_factory=list)


@dataclass
class Doc:
    slug: str
    title: str
    icon: str  # a key the app maps to an icon
    summary: list[str]
    sections: list[Section]
    updated: str = UPDATED

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


def _hours(h: int) -> str:
    return "48 heures" if h == 48 else f"{h} heures"


def documents(cfg: Settings, biz: dict[str, Any]) -> dict[str, Doc]:
    company, email = cfg.company_name, cfg.contact_email
    validity = _hours(int(biz["quote_validity_hours"]))
    days = int(biz["payment_deadline_days"])
    deadline = f"{days} jour{'s' if days > 1 else ''}"
    min_fee = f"{int(biz['min_fee_xof']):,}".replace(",", " ")

    how = Doc(
        "fonctionnement", "Comment ça marche et délais", "route",
        [
            "Tu envoies ton panier SHEIN ou Temu, on te fait un devis en FCFA.",
            "On n’achète rien avant que tu aies accepté le devis et payé.",
            "Les colis partent groupés chaque semaine par bateau : compte 2 à 4 semaines.",
        ],
        [
            Section("Les étapes", bullets=[
                "Tu remplis ton panier dans l’app SHEIN ou Temu, puis tu l’envoies à Flariane avec « Partager ».",
                "Notre équipe te prépare un devis : articles, transport, droits de douane et frais de service.",
                "Tu vérifies chaque article (taille, couleur), tu acceptes et tu paies avec Wave, Orange Money ou Moov.",
                "On commande ton panier. Il voyage avec les autres colis par bateau jusqu’à Abidjan.",
                "Quand il est prêt, on t’écrit sur WhatsApp avec un code à 6 chiffres.",
                "Tu retires ton colis au point de retrait en donnant ce code.",
            ]),
            Section("Le devis", paragraphs=[
                "Le prix est en FCFA : articles + transport + droits de douane + frais de service. "
                "Le taux de change est fixé au moment du devis.",
                f"Un devis est valable {validity}. Passé ce délai, tu peux en demander un nouveau.",
                f"Une commande non payée {deadline} après l’envoi du devis est annulée automatiquement.",
            ]),
            Section("Les délais", paragraphs=[
                "Les colis sont regroupés et expédiés par bateau, une fois par semaine. Compte 2 à 4 semaines entre le paiement "
                "et le retrait. C’est une estimation : les délais de SHEIN ou Temu et du transport peuvent varier.",
                "La date du prochain départ et la date limite pour être dans ce colis sont affichées sur l’écran d’accueil.",
            ]),
            Section("Le retrait", paragraphs=[
                "Ton colis t’attend au point de retrait choisi. Présente le code reçu sur WhatsApp : sans ce code, "
                "personne ne peut retirer ton colis.",
            ]),
        ],
    )

    terms = Doc(
        "conditions", "Conditions d’utilisation", "description",
        [
            f"{company} achète pour toi sur SHEIN ou Temu, après ton paiement.",
            "Tu vérifies tailles et couleurs avant de payer : les articles ne sont ni repris ni échangés.",
            "Tu paies le montant exact du devis par Wave, Orange Money ou Moov.",
        ],
        [
            Section("Qui nous sommes", paragraphs=[
                f"L’application Flariane est exploitée par {company}. Contact : {email}.",
            ]),
            Section("Le service", paragraphs=[
                f"{company} est un service d’achat et d’import : tu choisis tes articles dans ton panier SHEIN ou Temu, "
                "nous les achetons pour toi, les faisons venir à Abidjan et te les remettons à un point de retrait. "
                "Nous ne sommes ni SHEIN ni Temu et nous n’avons aucun lien officiel avec ces enseignes.",
            ]),
            Section("Devis et prix", paragraphs=[
                "Le montant à payer est celui du devis que tu as accepté. Il comprend les articles, le transport, les droits de douane "
                f"et nos frais de service (au minimum {min_fee} FCFA).",
                "Les prix affichés dans l’app SHEIN ou Temu peuvent différer de ceux au moment de notre commande. "
                "Si le prix d’un article augmente, nous l’absorbons ou nous te contactons avant d’acheter.",
                f"Un devis est valable {validity}.",
            ]),
            Section("Ton panier : tu vérifies", paragraphs=[
                "Avant d’accepter, tu vérifies chaque article : taille, couleur, quantité. En acceptant, tu confirmes que c’est correct. "
                "Nous achetons exactement ce qui figure sur le devis.",
                "Les articles ne peuvent pas être retournés ni échangés, sauf s’ils ne correspondent pas à ton devis "
                "(voir « Annulation et remboursement »).",
            ]),
            Section("Paiement", paragraphs=[
                "Tu paies avec Wave, Orange Money ou Moov, au numéro indiqué dans l’app, en écrivant la référence de ta commande. "
                "Tu nous envoies la capture du paiement ; notre équipe la vérifie et ta commande passe à « Payée ». "
                "Nous ne te demandons jamais ton code secret.",
            ]),
            Section("Ton compte", paragraphs=[
                "Ton compte est lié à ton numéro de téléphone (WhatsApp) et à ton mot de passe. Garde ton mot de passe pour toi : "
                "tu es responsable de ce qui est fait avec ton compte. Nous pouvons suspendre un compte en cas d’abus ou de fraude.",
            ]),
            Section("Retards, perte, dommages", paragraphs=[
                "Les délais sont indicatifs. Si ton colis est perdu, abîmé ou en retard, écris-nous : nous regardons chaque situation "
                "avec le transitaire et nous te répondons.",
            ]),
            Section("Droit applicable et changements", paragraphs=[
                "Ces conditions sont soumises au droit ivoirien. Si nous les modifions de façon importante, l’app te demande de les accepter à nouveau.",
            ]),
        ],
    )

    refund = Doc(
        "remboursement", "Annulation et remboursement", "undo",
        [
            "Avant de payer : tu peux annuler quand tu veux, sans frais.",
            "Après le paiement : écris-nous vite. On peut annuler tant que l’article n’est pas acheté.",
            "Si SHEIN ou Temu annule un article, on te rembourse cet article, avec le même moyen de paiement.",
        ],
        [
            Section("Avant le paiement", paragraphs=[
                "Tu peux annuler ta commande tant que tu n’as pas accepté le devis. Un devis qui expire, ou une commande non payée "
                f"{deadline} après l’envoi du devis, est annulé automatiquement. Aucun frais.",
                "Si tu as accepté le devis et que ton paiement est en attente de vérification, écris-nous avant de payer ou "
                "d’envoyer ta capture.",
            ]),
            Section("Après le paiement", paragraphs=[
                "Écris-nous le plus vite possible depuis le bouton « Une question ? ». Tant que nous n’avons pas acheté tes articles, "
                "nous annulons et te remboursons. Une fois la commande passée chez SHEIN ou Temu, elle ne peut plus être annulée.",
            ]),
            Section("Si un article n’est pas disponible", paragraphs=[
                "Si SHEIN ou Temu annule ou ne peut pas livrer un article, nous te remboursons le prix de cet article "
                "(et sa part de transport et de droits de douane). Le reste de ta commande continue.",
            ]),
            Section("Si l’article ne correspond pas au devis", paragraphs=[
                "Si l’article que tu retires n’est pas celui du devis (autre article, taille ou couleur différente de ce que tu as validé), "
                "écris-nous dès le retrait. Nous traitons ta demande avec toi. "
                "Si tu as validé la taille et la couleur, une erreur de choix ne donne pas droit à un remboursement.",
            ]),
            Section("Comment on te rembourse", paragraphs=[
                "Le remboursement se fait avec le même moyen de paiement que celui que tu as utilisé (Wave, Orange Money ou Moov), "
                "après vérification par notre équipe. Nous te prévenons sur WhatsApp.",
                "Les points de fidélité utilisés sur une commande non payée te sont rendus.",
            ]),
        ],
    )

    privacy = Doc(
        "confidentialite", "Politique de confidentialité", "privacy",
        [
            "On garde seulement ce qu’il faut pour traiter tes commandes.",
            "On ne vend pas tes données et on n’affiche pas de publicité.",
            "Tu peux voir tes données, les corriger ou supprimer ton compte à tout moment.",
        ],
        [
            Section("Qui est responsable", paragraphs=[
                f"{company} exploite l’application Flariane, qui permet de faire acheter des paniers SHEIN et Temu et de les retirer à Abidjan. "
                f"Contact : {email}.",
            ]),
            Section("Données collectées", bullets=[
                "Compte : numéro de téléphone (WhatsApp), prénom, mot de passe (stocké uniquement sous forme chiffrée irréversible).",
                "Commandes : liens de panier SHEIN/Temu, captures d’écran de panier que tu envoies, devis, statut des commandes.",
                "Paiement : moyen choisi (Wave, Orange Money, Moov) et la capture d’écran du paiement. Nous ne recevons jamais tes codes ni tes identifiants de paiement.",
                "Adresse à Abidjan : commune, quartier, repère et, si tu l’acceptes, ta position GPS.",
                "Fidélité : tes points et ton code de parrainage.",
            ]),
            Section("Utilisation", paragraphs=[
                "Ces données servent uniquement à vérifier ton numéro, établir tes devis, passer tes commandes, organiser la livraison "
                "et le retrait, et te contacter sur WhatsApp au sujet de tes commandes. Nous ne vendons pas tes données et "
                "n’affichons pas de publicité.",
            ]),
            Section("Partage", paragraphs=[
                "Nous communiquons au transitaire et au point de retrait uniquement ce qui est nécessaire à la livraison "
                "(référence de commande, prénom). Les données sont hébergées chez nos prestataires techniques (hébergement du serveur "
                "et de la base de données) dans l’Union européenne.",
            ]),
            Section("Sécurité", paragraphs=[
                "Ton numéro de téléphone et ton adresse sont chiffrés dans notre base de données. Les échanges avec l’application "
                "sont chiffrés (HTTPS). L’accès de notre équipe est protégé et journalisé.",
            ]),
            Section("Conservation et suppression", paragraphs=[
                "Tu peux supprimer ton compte à tout moment depuis l’application : Mon compte › Supprimer mon compte. "
                "Tes données personnelles sont alors effacées ; seules les informations comptables des commandes payées sont "
                "conservées, sans lien avec ton identité, comme l’exige la loi.",
            ]),
            Section("Tes droits", paragraphs=[
                "Conformément à la loi ivoirienne n° 2013-450 relative à la protection des données à caractère personnel, tu peux "
                f"accéder à tes données, les corriger ou les supprimer. Dans l’app : Infos et légal › Mes données. Ou écris-nous à {email}.",
            ]),
        ],
    )

    legal_lines = [f"Nom : {company}"]
    if cfg.company_address:
        legal_lines.append(f"Adresse : {cfg.company_address}")
    if cfg.company_registration:
        legal_lines.append(f"Immatriculation (RCCM / CEPICI) : {cfg.company_registration}")
    legal_lines.append(f"Contact : {email}")
    notice = Doc(
        "mentions-legales", "Mentions légales", "business",
        [f"Application éditée par {company}.", f"Contact : {email}."],
        [
            Section("Éditeur", bullets=legal_lines),
            Section("Hébergement", paragraphs=[
                "Le serveur et la base de données sont hébergés chez des prestataires techniques situés dans l’Union européenne.",
            ]),
            Section("Marques", paragraphs=[
                "SHEIN et Temu sont des marques de leurs propriétaires respectifs. Flariane n’est pas affiliée à ces enseignes.",
            ]),
        ],
    )
    return {d.slug: d for d in (how, terms, refund, privacy, notice)}
