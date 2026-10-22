#!/bin/bash
# Creates the Google Play *upload* key and android/key.properties (both git-ignored).
# Run once:  bash android/create_upload_key.sh
# BACK UP the .jks file and the password (password manager). Losing them means asking Google
# to reset the upload key (Play App Signing keeps the real app-signing key).
set -euo pipefail
cd "$(dirname "$0")"
KEYSTORE="$HOME/flariane-upload-keystore.jks"
if [ -e "$KEYSTORE" ]; then echo "$KEYSTORE already exists"; exit 1; fi
read -r -s -p "Choisis un mot de passe pour la clé (12+ caractères) : " PASS; echo
keytool -genkey -v -keystore "$KEYSTORE" -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 \
  -alias upload -storepass "$PASS" -keypass "$PASS" \
  -dname "CN=Flariane, O=Flariane, L=Abidjan, C=CI"
cat > key.properties <<EOF
storePassword=$PASS
keyPassword=$PASS
keyAlias=upload
storeFile=$KEYSTORE
EOF
chmod 600 key.properties
echo "OK : $KEYSTORE et android/key.properties créés. Sauvegarde-les !"
