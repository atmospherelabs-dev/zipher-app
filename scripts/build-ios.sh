#!/usr/bin/env bash
set -euo pipefail

PUBSPEC="$(dirname "$0")/../pubspec.yaml"

# Extract current version and build number
CURRENT=$(grep '^version:' "$PUBSPEC" | sed 's/version: //')
VERSION_NAME=$(echo "$CURRENT" | cut -d'+' -f1)
BUILD_NUM=$(echo "$CURRENT" | cut -d'+' -f2)

# Bump build number
NEW_BUILD=$((BUILD_NUM + 1))
NEW_VERSION="${VERSION_NAME}+${NEW_BUILD}"

sed -i '' "s/^version: .*/version: ${NEW_VERSION}/" "$PUBSPEC"
echo "Bumped build: ${CURRENT} → ${NEW_VERSION}"

flutter build ipa --build-name="$VERSION_NAME" --build-number="$NEW_BUILD"

echo ""
echo "Done. To distribute:"
echo "  open build/ios/archive/Runner.xcarchive"
