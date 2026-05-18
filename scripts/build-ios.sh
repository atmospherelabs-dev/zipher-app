#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
PUBSPEC="${WORKSPACE}/pubspec.yaml"
VERSION_DART="${WORKSPACE}/lib/src/version.dart"
ARCHIVE_PATH="${WORKSPACE}/build/ios/archive/Runner.xcarchive"
IPA_DIR="${WORKSPACE}/build/ios/ipa"
EXPORT_OPTIONS="${IPA_DIR}/ExportOptions.plist"
EXPECTED_IPA="${IPA_DIR}/Zipher.ipa"

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
# Codegen (.g.dart / .freezed.dart are gitignored — must regen each build)
# ----------------------------------------------------------------------------
echo "Running build_runner..."
dart run build_runner build --delete-conflicting-outputs

# ----------------------------------------------------------------------------
# Delete the stale IPA so we can never accidentally upload yesterday's build
# if the export step silently fails.
# ----------------------------------------------------------------------------
rm -f "$EXPECTED_IPA"

# ----------------------------------------------------------------------------
# Build via flutter. This produces both the archive AND attempts the export.
# When signing is healthy this is enough. We still verify afterwards.
# ----------------------------------------------------------------------------
echo "Building IPA via flutter..."
flutter build ipa --build-name="$VERSION_NAME" --build-number="$NEW_BUILD"

# ----------------------------------------------------------------------------
# Verify the IPA's actual CFBundleVersion matches what we asked for. If
# flutter build ipa's internal export silently failed, the IPA either won't
# exist or will be from a prior build.
# ----------------------------------------------------------------------------
verify_ipa_build() {
    local ipa="$1"
    if [ ! -f "$ipa" ]; then
        return 1
    fi
    local actual
    actual=$(unzip -p "$ipa" 'Payload/Runner.app/Info.plist' 2>/dev/null \
        | plutil -extract CFBundleVersion raw -o - - 2>/dev/null || echo "")
    if [ "$actual" != "$NEW_BUILD" ]; then
        echo "  IPA build number mismatch: expected $NEW_BUILD, found '$actual'"
        return 1
    fi
    return 0
}

# Fallback: if the IPA is stale or missing but the archive landed correctly,
# run the export ourselves using xcodebuild with --allowProvisioningUpdates
# so provisioning profile fetches happen automatically.
if ! verify_ipa_build "$EXPECTED_IPA"; then
    echo ""
    echo "Flutter's IPA export did not produce a fresh build $NEW_BUILD."
    if [ ! -d "$ARCHIVE_PATH" ]; then
        echo "❌ No archive found at $ARCHIVE_PATH — the build step itself failed."
        exit 1
    fi
    archive_build=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" \
        "$ARCHIVE_PATH/Info.plist" 2>/dev/null || echo "")
    if [ "$archive_build" != "$NEW_BUILD" ]; then
        echo "❌ Archive is at build '$archive_build', expected $NEW_BUILD."
        echo "   Something is very wrong with the build pipeline."
        exit 1
    fi
    echo "Archive is at the right build ($archive_build). Re-exporting with xcodebuild..."
    rm -f "$EXPECTED_IPA"
    # Don't let xcodebuild's non-zero exit kill us — we want to fall through
    # to the diagnostic block below and tell the user what to do.
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$IPA_DIR" \
        -allowProvisioningUpdates || true
fi

# Last-resort verification.
if ! verify_ipa_build "$EXPECTED_IPA"; then
    echo ""
    echo "================================================================"
    echo "❌ Could not produce a signed IPA at build $NEW_BUILD."
    echo "================================================================"
    echo ""
    echo "Likely cause: Apple Distribution signing is broken on this Mac."
    echo ""
    echo "Check signing identities currently in the keychain:"
    security find-identity -p codesigning -v 2>&1 | sed 's/^/   /'
    echo ""
    echo "For App Store / TestFlight distribution we need an 'Apple"
    echo "Distribution' entry above. If we only see 'Apple Development'"
    echo "entries, the dist cert is missing."
    echo ""
    echo "Fastest fix path:"
    echo "  1. Xcode → Settings → Accounts. Sign in to the Atmosphere"
    echo "     Labs Apple Developer account if not already signed in."
    echo "  2. Xcode → Window → Organizer (we'll open it for you below)."
    echo "  3. Pick the build $NEW_BUILD archive → Distribute App →"
    echo "     App Store Connect → Automatically manage signing. Xcode"
    echo "     will provision a dist cert as part of distribution and"
    echo "     upload directly. Future builds via this script will"
    echo "     pick up the new cert automatically."
    echo ""
    echo "Archive that needs distribution:"
    echo "  $ARCHIVE_PATH"
    echo ""
    if command -v open >/dev/null 2>&1; then
        echo "Opening Xcode Organizer now..."
        open -a Xcode "$ARCHIVE_PATH" || true
    fi
    exit 1
fi

echo ""
echo "✓ Verified IPA: ${EXPECTED_IPA}"
echo "  build number: $NEW_BUILD"
echo "  commit:       $COMMIT"

# ----------------------------------------------------------------------------
# Mirror the archive into Xcode's canonical Archives location so it shows up
# in Xcode → Window → Organizer. `flutter build ipa` writes only to the
# project's build/ios/archive/ folder, which Organizer ignores.
# ----------------------------------------------------------------------------
ORGANIZER_DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
ORGANIZER_ARCHIVE="${ORGANIZER_DIR}/Zipher_${NEW_VERSION}.xcarchive"
if [ -d "$ARCHIVE_PATH" ]; then
    mkdir -p "$ORGANIZER_DIR"
    rm -rf "$ORGANIZER_ARCHIVE"
    # ditto preserves resource forks, ACLs, extended attributes — required
    # for an xcarchive that Xcode will recognize.
    ditto "$ARCHIVE_PATH" "$ORGANIZER_ARCHIVE"
    echo "  archive:      $ORGANIZER_ARCHIVE  (visible in Xcode Organizer)"
fi

# ----------------------------------------------------------------------------
# Optional auto-upload via altool. Requires App Store Connect API key.
# Drop the .p8 at ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 and set:
#   export APPSTORE_API_KEY=<KEYID>
#   export APPSTORE_API_ISSUER=<ISSUER_UUID>
# If either env var is unset, we skip and ask you to upload manually.
# ----------------------------------------------------------------------------
if [ -n "${APPSTORE_API_KEY:-}" ] && [ -n "${APPSTORE_API_ISSUER:-}" ]; then
    echo ""
    echo "Uploading to App Store Connect via altool..."
    xcrun altool --upload-app \
        --type ios \
        --file "$EXPECTED_IPA" \
        --apiKey "$APPSTORE_API_KEY" \
        --apiIssuer "$APPSTORE_API_ISSUER"
    echo ""
    echo "✓ Uploaded build $NEW_BUILD to App Store Connect."
    echo "  TestFlight processing usually takes 5–30 minutes."
else
    echo ""
    echo "Upload manually:"
    echo "  open -a Transporter \"$EXPECTED_IPA\""
    echo "Or, to auto-upload on future builds, set:"
    echo "  export APPSTORE_API_KEY=<KEY_ID>"
    echo "  export APPSTORE_API_ISSUER=<ISSUER_UUID>"
fi
