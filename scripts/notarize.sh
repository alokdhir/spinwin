#!/usr/bin/env bash
# Builds, notarizes, and staples SpinWin.app, then packages it as a zip that
# downloads and launches without Gatekeeper warnings.
#
# Notarization needs App Store Connect API credentials. Provide them via a
# stored keychain profile (recommended) or environment variables:
#
#   Stored profile (set up once):
#     xcrun notarytool store-credentials spinwin-notary \
#       --key ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
#       --key-id XXXX --issuer <ISSUER_UUID>
#     ./scripts/notarize.sh
#
#   Or inline, no stored profile:
#     NOTARY_KEY=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
#     NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<ISSUER_UUID> ./scripts/notarize.sh
#
# Override the profile name with NOTARY_PROFILE (default: spinwin-notary).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/SpinWin.app"
PROFILE="${NOTARY_PROFILE:-spinwin-notary}"

# Assemble the notarytool auth arguments from whichever method is configured.
auth_args=()
if [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
	auth_args=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
	echo "Using inline App Store Connect API key ($NOTARY_KEY_ID)."
else
	auth_args=(--keychain-profile "$PROFILE")
	echo "Using stored notary profile: $PROFILE"
fi

# 1. Build + sign with a secure timestamp (required for notarization).
echo "==> Building signed release (with secure timestamp)…"
TIMESTAMP=1 "$ROOT/scripts/build-app.sh" release

VER="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
ZIP="$ROOT/SpinWin-$VER.zip"

# 2. Zip and submit for notarization.
echo "==> Packaging for submission…"
rm -f "$ZIP"
# --norsrc/--noextattr keep AppleDouble "._" companion files out of the archive,
# which otherwise litter the download when someone unzips it.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$ZIP" "${auth_args[@]}" --wait

# 3. Staple the ticket into the app, then re-zip the stapled bundle.
echo "==> Stapling ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Re-packaging stapled app…"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

echo
echo "Done: $ZIP (notarized + stapled, version $VER)"
echo "Verify Gatekeeper acceptance with:  spctl -a -vvv --type exec '$APP'"
