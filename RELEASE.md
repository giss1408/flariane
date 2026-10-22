# Publier l'application cliente

## Avant tout : serveur de production
Sur Render (`flariane-api` → Environment) :
- `FLR_ENV=prod` (désactive définitivement les routes de test, active HSTS)
- `FLR_DEV_ROUTES=false`, supprimer `FLR_SETUP_TOKEN`
- `FLR_CONTACT_EMAIL=<ton e-mail de contact public>` (affiché sur les pages légales)
- Stockage des captures : `FLR_STORAGE_MODE=s3` + R2/S3 (sinon les captures de panier sont perdues au redémarrage)
- Plan Render payant conseillé (le plan gratuit met ~1 min à se réveiller : mauvaise première impression, et refus possible en revue)
- Paramètres (app admin) : numéros Wave / Orange / Moov, numéro WhatsApp support, prochain départ.

## Android — Google Play
1. Compte développeur Google Play (25 $ une fois) : https://play.google.com/console
2. Clé d'envoi (une seule fois) : `bash customer_app/android/create_upload_key.sh` → **sauvegarde** le .jks et le mot de passe.
3. Bundle : `cd customer_app && flutter build appbundle --release`
   → `build/app/outputs/bundle/release/app-release.aab`
4. Play Console → Créer l'app → remplir la fiche avec `customer_app/store/LISTING.md` → Test interne d'abord, puis Production.
5. Accepter **Play App Signing** (Google garde la clé de signature finale).
6. Nouveau compte développeur personnel : Google exige un **test fermé avec 12 testeurs pendant 14 jours** avant la production.

## iOS — App Store
Ce Mac (macOS 13, Xcode 15.2) **ne peut pas soumettre** : Apple exige Xcode 16+ (SDK iOS 18).
Options : un Mac sous macOS 14+, ou un service de build cloud (Codemagic, gratuit pour démarrer).
1. Compte Apple Developer (99 $/an) : https://developer.apple.com
2. App Store Connect → nouvelle app, bundle ID `ci.flariane.flariane`.
3. Sur un Mac à jour : `cd customer_app && flutter build ipa --release` puis Transporter / Xcode Organizer.
4. Fiche : `customer_app/store/LISTING.md` (sous-titre, mots-clés, confidentialité, compte de démo).
5. À prévoir côté iOS : l'extension de partage (« Partager → Flariane » depuis SHEIN/Temu) n'existe pas encore ;
   sur iPhone, la cliente colle le lien du panier.

## Versions suivantes
Augmenter `version:` dans `customer_app/pubspec.yaml` (ex. `1.0.1+2` : le nombre après `+` doit toujours augmenter).

## Attention aux marques
Apple et Google refusent les apps qui semblent officielles pour une marque tierce. Flariane n'utilise ni logo
SHEIN/Temu ni leurs noms dans l'icône ou le nom ; la description précise « non affilié ». Si un relecteur bloque,
retirer « SHEIN/Temu » de l'image de présentation et des mots-clés.
