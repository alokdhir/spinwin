#!/usr/bin/env bash
# Builds SpinWin.app: a proper .app bundle so macOS grants a stable identity
# for the Screen Recording and Accessibility permission prompts.
#
# Signs with a stable code-signing identity so rebuilds keep the SAME TCC
# permission grant (ad-hoc signatures change every build, which makes macOS
# forget the permission and re-prompt endlessly).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/SpinWin.app"

# Prefer a real Developer ID / Apple Development identity; fall back to ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
	SIGN_IDENTITY="$(security find-identity -v -p codesigning | \
		grep -Eo '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"' || true)"
fi
[ -z "$SIGN_IDENTITY" ] && SIGN_IDENTITY="-"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/SpinWin"

echo "Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SpinWin"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
	cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "Signing with: $SIGN_IDENTITY"
if [ "$SIGN_IDENTITY" = "-" ]; then
	echo "WARNING: no Developer ID/Apple Development identity found; signing ad-hoc." >&2
	echo "         macOS will re-prompt for Screen Recording/Accessibility on every rebuild." >&2
	codesign --force --sign - "$APP"
else
	# By default skip Apple's secure timestamp server (offline-friendly); without
	# it, hardened-runtime signing still succeeds locally and TCC permissions
	# persist across rebuilds. Notarization, however, REQUIRES a secure
	# timestamp, so `scripts/notarize.sh` sets TIMESTAMP=1 to request one.
	if [ "${TIMESTAMP:-0}" = "1" ]; then
		TS_FLAG="--timestamp"
	else
		TS_FLAG="--timestamp=none"
	fi
	codesign --force --options runtime "$TS_FLAG" --sign "$SIGN_IDENTITY" "$APP"
fi

# Fail loudly if we didn't end up with the intended stable signature.
if [ "$SIGN_IDENTITY" != "-" ]; then
	SIG_INFO="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
	case "$SIG_INFO" in
		*TeamIdentifier=*) ;;
		*)
			echo "ERROR: signing did not apply a Team identity; permissions will not persist." >&2
			exit 1
			;;
	esac
fi

echo "Done: $APP"
echo "Run with: open \"$APP\"   (grant Screen Recording + Accessibility when prompted)"

