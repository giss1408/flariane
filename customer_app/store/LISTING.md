# Fiche magasin — Flariane (application cliente)

Identifiant : `com.regisse.flariane` (Android et iOS) · Version : 1.0.1 (7) · Catégorie : **Shopping**
Pays : Côte d'Ivoire (+ France si tu veux tester depuis l'Europe) · Langue principale : **Français**
Confidentialité : https://flariane-api.regisse.com/legal/confidentialite
Suppression de compte : https://flariane-api.regisse.com/legal/suppression-compte
Support : https://flariane-api.regisse.com/legal/support · Copyright : 2026 Regisse · E-mail de contact : flariane@regisse.com

## Textes

**Nom** (30 car. max) : `Flariane`

**Sous-titre App Store** (30) : `Tes paniers livrés à Abidjan`

**Description courte Google Play** (80) :
`Envoie ton panier en ligne, reçois ton devis en FCFA, retire à Abidjan.`

**Texte promotionnel App Store** (170) :
`Remplis ton panier, envoie le lien à Flariane, reçois ton prix en FCFA et paie avec Wave, Orange Money ou Moov Money.`

**Description complète** (Play 4000 / App Store 4000) :
```
Flariane, c'est le moyen simple de recevoir à Abidjan tes paniers de boutiques en ligne.

COMMENT ÇA MARCHE
1. Remplis ton panier dans l'app de ta boutique en ligne, comme d'habitude.
2. Copie le lien de ton panier et colle-le dans Flariane. (Android : tu peux aussi utiliser Partager → Flariane.)
3. Reçois ton devis en FCFA, avec la capture de ton panier : tu sais exactement ce que nous commandons.
4. Paie avec Wave, Orange Money ou Moov Money et envoie la capture de ton paiement.
5. Suis ta commande étape par étape et retire ton colis à Abidjan avec ton code de retrait.

POURQUOI FLARIANE
• Prix clair en FCFA : panier + transport jusqu'à Abidjan, rien de caché.
• Tu vérifies la capture de ton panier avant de payer.
• Paiement mobile money : Wave, Orange Money, Moov Money.
• Suivi de ta commande et prochain départ affichés dans l'app.
• Une question ? Écris-nous sur WhatsApp depuis l'app.
• Retrait sécurisé avec un code à 6 chiffres.

Flariane est un service indépendant d'achat et de livraison. Flariane n'est affilié à aucune boutique en ligne
et n'est approuvé par aucune marque.
```

**Mots-clés App Store** (100) :
`abidjan,côte d'ivoire,livraison,colis,mode,wave,orange money,moov,achat,panier,commande,transport`

Pas de nom de marque tierce (SHEIN, Temu…) dans les mots-clés, le sous-titre ou la description : règle 2.3.7 d'Apple
et `CLAUDE.md`. Les noms peuvent apparaître dans les notes de revue, pas dans les textes publics.

**Nouveautés 1.0.1** : `Première version de Flariane.`

## Classification
- Google Play : questionnaire IARC → pas de violence, pas de contenu sensible, achats de biens physiques → **Tout public / 3+**.
- App Store : 4+. Pas d'achats intégrés (les paiements concernent des biens physiques, hors In-App Purchase : autorisé, règle 3.1.3(e)).

## Google Play — Sécurité des données
| Donnée | Collectée | Partagée | Finalité | Facultative |
|---|---|---|---|---|
| Numéro de téléphone | Oui | Non | Gestion du compte, communications | Non |
| Nom (prénom) | Oui | Non | Gestion du compte | Oui |
| Adresse (commune, quartier, repère) | Oui | Non | Fonctionnalités de l'app (livraison) | Oui |
| Position approximative / précise | Oui | Non | Fonctionnalités de l'app (livraison) | Oui |
| Photos (captures panier / paiement) | Oui | Non | Fonctionnalités de l'app | Oui |
| Historique d'achats (commandes) | Oui | Non | Fonctionnalités de l'app | Non |
| Journaux de plantage et diagnostics (Sentry) | Oui | Non | Analyse / stabilité de l'app | Non |

Chiffrées en transit : **Oui**. L'utilisateur peut demander la suppression : **Oui** (dans l'app + URL ci-dessus).
Pas de publicité, pas de suivi. Rapports de plantage via Sentry (UE), sans corps de requête, IP ni capture d'écran.

## App Store — Confidentialité de l'app
Données liées à l'identité, **non utilisées pour le suivi** : Coordonnées (téléphone, nom, adresse),
Position (précise, facultative), Contenu utilisateur (photos), Achats (historique),
Diagnostics (données de plantage, non liées à l'identité).
Suivi (ATT) : **Non**.

## Compte de démonstration pour les testeurs Apple / Google (obligatoire)
Crée une cliente de test **avec numéro vérifié** (Admin → Inscriptions à vérifier → envoyer le code) puis indique :
- Numéro : `0700000099` · Mot de passe : saisi dans App Store Connect et Play Console (jamais versionné ici)
- Note : « Pour tester, envoyez un lien de panier SHEIN (ex. https://onelink.shein.com/…).
  Le devis est établi manuellement par notre équipe sous 2 h en journée (heure d'Abidjan). »

## Visuels
- `graphics/play-icon-512.png` — icône Google Play 512×512
- `graphics/play-feature-graphic-1024x500.png` — image de présentation Google Play
- Captures d'écran : au moins 2 (Play) ; App Store : 6,7" (1290×2796) et 6,5" (1284×2778).
  Fais-les sur ton téléphone avec un compte de démo rempli (accueil, devis avec capture, paiement, suivi).
