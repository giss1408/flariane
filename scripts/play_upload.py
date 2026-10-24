"""Upload an Android App Bundle to a Google Play track from this Mac (fallback when
Codemagic is unavailable; Codemagic's "customer-android" workflow is the normal path).

    python3 -m venv ~/.venvs/flariane-release
    ~/.venvs/flariane-release/bin/pip install -r scripts/requirements-release.txt
    cd customer_app && flutter build appbundle --release && cd ..
    ~/.venvs/flariane-release/bin/python scripts/play_upload.py \
        --key ~/secrets/flariane-play-service-account.json --track alpha

The service account needs "Release apps to testing tracks" (or "Release to production")
on the app in Play Console → Users and permissions. Keep its JSON key out of the repo.
"""

import argparse
from pathlib import Path

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

PACKAGE = "com.regisse.flariane"
DEFAULT_AAB = Path(__file__).resolve().parent.parent / "customer_app/build/app/outputs/bundle/release/app-release.aab"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--key", required=True, type=Path, help="service account JSON key")
    parser.add_argument("--aab", type=Path, default=DEFAULT_AAB)
    parser.add_argument("--track", default="alpha", help="internal, alpha (closed test), beta, production")
    parser.add_argument("--notes", default="Corrections et améliorations.", help="release notes (fr-FR)")
    parser.add_argument("--draft", action="store_true", help="leave the release as a draft in Play Console")
    args = parser.parse_args()

    credentials = service_account.Credentials.from_service_account_file(
        args.key, scopes=["https://www.googleapis.com/auth/androidpublisher"]
    )
    edits = build("androidpublisher", "v3", credentials=credentials, cache_discovery=False).edits()

    edit_id = edits.insert(packageName=PACKAGE, body={}).execute()["id"]
    bundle = edits.bundles().upload(
        packageName=PACKAGE,
        editId=edit_id,
        media_body=MediaFileUpload(str(args.aab), mimetype="application/octet-stream", resumable=True),
    ).execute()
    version_code = str(bundle["versionCode"])
    print(f"Uploaded version code {version_code}")

    edits.tracks().update(
        packageName=PACKAGE,
        editId=edit_id,
        track=args.track,
        body={
            "track": args.track,
            "releases": [
                {
                    "versionCodes": [version_code],
                    "status": "draft" if args.draft else "completed",
                    "releaseNotes": [{"language": "fr-FR", "text": args.notes}],
                }
            ],
        },
    ).execute()
    # With managed publishing off, a committed edit goes to Google review on its own.
    edits.commit(packageName=PACKAGE, editId=edit_id).execute()
    print(f"Committed to track {args.track} ({'draft' if args.draft else 'sent for review'})")


if __name__ == "__main__":
    main()
