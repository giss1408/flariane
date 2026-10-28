#!/usr/bin/env python3
"""Create or reset the Flariane super admin on the server, safely (no shell escaping issues).

Usage:  python3 setup_admin.py
        FLR_API_BASE_URL=https://flariane-api-test.onrender.com python3 setup_admin.py   (test server)
Asks for the setup token and the password without echoing them, builds the JSON itself,
and prints the authenticator key to add to Google Authenticator / 1Password.
"""
import getpass
import json
import os
import urllib.error
import urllib.request

API = os.environ.get("FLR_API_BASE_URL", "https://flariane-api.onrender.com").rstrip("/")

token = getpass.getpass("FLR_SETUP_TOKEN (from Render > Environment): ").strip()
email = input("Email: ").strip().lower()
name = input("Prénom: ").strip() or "Admin"
password = getpass.getpass("Mot de passe (12+ caractères): ")
if getpass.getpass("Confirme le mot de passe: ") != password:
    raise SystemExit("Les mots de passe diffèrent.")

body = json.dumps({"email": email, "name": name, "role": "SUPER_ADMIN", "password": password}).encode()
req = urllib.request.Request(f"{API}/setup/reset-admin", data=body, method="POST",
                             headers={"content-type": "application/json", "x-setup-token": token})
try:
    with urllib.request.urlopen(req, timeout=120) as resp:  # Render free may take ~1 min to wake up
        data = json.load(resp)
except urllib.error.HTTPError as e:
    raise SystemExit(f"Erreur {e.code}: {e.read().decode()}")

print("\nCompte prêt :", data["email"])
print("Clé à ajouter dans ton app d'authentification (basée sur le temps) :")
print("   ", data["totp_secret"])
print("\nConnecte-toi ensuite dans l'app admin : ton téléphone sera approuvé automatiquement.")
print("Pense à supprimer FLR_SETUP_TOKEN sur Render quand tout marche.")
