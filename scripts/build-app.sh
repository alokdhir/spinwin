#!/usr/bin/env bash
# Builds RotateWin.app: a proper .app bundle so macOS grants a stable identity
# for the Screen Recording and Accessibility permission prompts.
#
# Signs with a stable code-signing identity so rebuilds keep the SAME TCC
# permission grant (ad-hoc signatures change every build, which makes macOS
# forget the permission and re-prompt endlessly).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/RotateWin.app"

# Prefer a real Developer ID / Apple Development identity; fall back to ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
	SIGN_IDENTITY="$(security find-identity -v -p codesigning | \
		grep -Eo '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"' || true)"
fi
[ -z "$SIGN_IDENTITY" ] && SIGN_IDENTITY="-"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/RotateWin"

echo "Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RotateWin"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "Signing with: $SIGN_IDENTITY"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"

echo "Done: $APP"
echo "Run with: open \"$APP\"   (grant Screen Recording + Accessibility when prompted)"

