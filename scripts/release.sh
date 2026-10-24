#!/bin/bash
# Release the customer app to both stores.
#
#   bash scripts/release.sh            # same version name, build number +1
#   bash scripts/release.sh patch      # 1.0.1 → 1.0.2 (build +1); also: minor, major
#   bash scripts/release.sh --dry-run patch
#
# Bumps customer_app/pubspec.yaml, commits only that file, tags customer-v<name>+<build>
# and pushes. The tag starts the Codemagic workflows "customer-ios" (→ TestFlight) and
# "customer-android" (→ Google Play closed test). See RELEASE.md, "Publication automatique".
set -euo pipefail
cd "$(dirname "$0")/.."

PUBSPEC=customer_app/pubspec.yaml
DRY_RUN=false
BUMP=build
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    build|patch|minor|major) BUMP=$arg ;;
    *) echo "Usage: $0 [--dry-run] [build|patch|minor|major]"; exit 1 ;;
  esac
done

[ "$(git branch --show-current)" = main ] || { echo "Release from main only."; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || git merge-base --is-ancestor origin/main HEAD \
  || { echo "main is behind origin/main: pull first."; exit 1; }
git diff --quiet -- "$PUBSPEC" && git diff --cached --quiet -- "$PUBSPEC" \
  || { echo "$PUBSPEC has uncommitted changes."; exit 1; }

CURRENT=$(sed -n 's/^version: *//p' "$PUBSPEC")
NAME=${CURRENT%+*}
BUILD=${CURRENT#*+}
IFS=. read -r MAJOR MINOR PATCH <<<"$NAME"
case "$BUMP" in
  major) NAME="$((MAJOR + 1)).0.0" ;;
  minor) NAME="$MAJOR.$((MINOR + 1)).0" ;;
  patch) NAME="$MAJOR.$MINOR.$((PATCH + 1))" ;;
esac
NEXT="$NAME+$((BUILD + 1))"
TAG="customer-v$NEXT"

echo "Version : $CURRENT → $NEXT  (tag $TAG)"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Note : other uncommitted changes stay out of the release commit (the tag builds HEAD)."
fi
$DRY_RUN && { echo "Dry run: nothing changed."; exit 0; }

(cd customer_app && flutter test)

sed -i '' "s/^version: .*/version: $NEXT/" "$PUBSPEC"
git commit -q -m "Customer app: version $NEXT" -- "$PUBSPEC"
git tag -a "$TAG" -m "Customer app $NEXT"
git push -q origin main "$TAG"
echo "Pushed $TAG: Codemagic now builds iOS (TestFlight) and Android (Play, closed test)."
echo "Follow it on https://codemagic.io/apps"
