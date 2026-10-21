"""Customer location in Abidjan (commune + quartier + landmark + optional GPS)."""

import json
from typing import Any

from app.security.crypto import decrypt, encrypt

# District autonome d'Abidjan: the 10 communes plus the 3 sub-prefectures served.
COMMUNES = [
    "Abobo", "Adjamé", "Attécoubé", "Cocody", "Koumassi", "Marcory", "Plateau", "Port-Bouët",
    "Treichville", "Yopougon", "Anyama", "Bingerville", "Songon",
]


def pack(quartier: str, landmark: str | None, lat: float | None, lng: float | None) -> bytes:
    return encrypt(json.dumps({"quartier": quartier, "landmark": landmark, "lat": lat, "lng": lng}, ensure_ascii=False))


def unpack(commune: str | None, blob: bytes | None) -> dict[str, Any] | None:
    if commune is None or blob is None:
        return None
    data = json.loads(decrypt(blob))
    data["commune"] = commune
    lat, lng = data.get("lat"), data.get("lng")
    data["maps_url"] = f"https://www.google.com/maps/search/?api=1&query={lat},{lng}" if lat is not None and lng is not None else None
    return data
