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

# Regenerate the in-app version banner so the More tab matches the binary.
COMMIT=$(git rev-parse HEAD)
VERSION_DART="$(dirname "$0")/../lib/src/version.dart"
cat > "$VERSION_DART" <<EOF
// Generated code. Do not modify.
const packageVersion = '${NEW_VERSION}';
const commitId = '${COMMIT}';
EOF
echo "Wrote ${VERSION_DART} (version=${NEW_VERSION} commit=${COMMIT})"

# Regenerate codegen output (.g.dart / .freezed.dart). These are
# gitignored so we need a clean rebuild before every IPA, otherwise new
# observables / new FRB fields won't be wired up.
echo "Running build_runner..."
dart run build_runner build --delete-conflicting-outputs

flutter build ipa --build-name="$VERSION_NAME" --build-number="$NEW_BUILD"

echo ""
echo "Done. To distribute:"
echo "  open build/ios/archive/Runner.xcarchive"
