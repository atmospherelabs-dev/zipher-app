#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
PUBSPEC="${WORKSPACE}/pubspec.yaml"
VERSION_DART="${WORKSPACE}/lib/src/version.dart"
AAB_DIR="${WORKSPACE}/build/app/outputs/bundle/release"
EXPECTED_AAB="${AAB_DIR}/app-release.aab"

# ----------------------------------------------------------------------------
# Version bump
# ----------------------------------------------------------------------------
CURRENT=$(grep '^version:' "$PUBSPEC" | sed 's/version: //')
VERSION_NAME=$(echo "$CURRENT" | cut -d'+' -f1)
BUILD_NUM=$(echo "$CURRENT" | cut -d'+' -f2)
NEW_BUILD=$((BUILD_NUM + 1))
NEW_VERSION="${VERSION_NAME}+${NEW_BUILD}"

sed -i '' "s/^version: .*/version: ${NEW_VERSION}/" "$PUBSPEC"
echo "Bumped build: ${CURRENT} → ${NEW_VERSION}"

COMMIT=$(git rev-parse HEAD)
cat > "$VERSION_DART" <<EOF
// Generated code. Do not modify.
const packageVersion = '${NEW_VERSION}';
const commitId = '${COMMIT}';
EOF
echo "Wrote ${VERSION_DART} (version=${NEW_VERSION} commit=${COMMIT})"

# ----------------------------------------------------------------------------
# Codegen
# ----------------------------------------------------------------------------
echo "Running build_runner..."
dart run build_runner build --delete-conflicting-outputs

# ----------------------------------------------------------------------------
# Build AAB
# ----------------------------------------------------------------------------
rm -f "$EXPECTED_AAB"

echo "Building Android App Bundle..."
flutter build appbundle --build-name="$VERSION_NAME" --build-number="$NEW_BUILD"

if [ ! -f "$EXPECTED_AAB" ]; then
    echo ""
    echo "❌ AAB not found at $EXPECTED_AAB"
    exit 1
fi

echo ""
echo "✓ Built AAB: ${EXPECTED_AAB}"
echo "  version:    ${NEW_VERSION}"
echo "  commit:     ${COMMIT}"
echo ""
echo "Upload to Google Play Console:"
echo "  Open https://play.google.com/console"
echo "  → Zipher → Testing → Open testing → Create new release"
echo "  → Upload ${EXPECTED_AAB}"
