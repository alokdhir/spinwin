#!/usr/bin/env bash
# Profiles SpinWin for memory leaks with Instruments' Leaks template.
#
# SpinWin's leak-prone areas are the RotationSession lifecycle (hide ->
# capture -> overlay) and the deliberate IOSurface/pixel-buffer retain in
# CaptureEngine, so exercise start/stop, drag, spin, and re-pick while it runs.
#
# Usage:
#   ./scripts/leak-check.sh            # profile the loose debug binary
#   ./scripts/leak-check.sh app        # profile the signed SpinWin.app bundle
#
# Requires Xcode command line tools (xctrace). Results are written to a
# timestamped .trace bundle you can open in Instruments for details.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-binary}"
STAMP="$(date +%Y%m%d-%H%M%S)"
TRACE="$ROOT/SpinWin-leaks-$STAMP.trace"

if [[ "$MODE" == "app" ]]; then
  TARGET="$ROOT/SpinWin.app"
  [[ -d "$TARGET" ]] || { echo "Build it first: ./scripts/build-app.sh" >&2; exit 1; }
else
  swift build
  TARGET="$ROOT/.build/debug/SpinWin"
fi

echo "Recording leaks to: $TRACE"
echo "Exercise start/stop, drag, spin, and re-pick, then quit SpinWin."

xcrun xctrace record \
  --template "Leaks" \
  --output "$TRACE" \
  --launch -- "$TARGET"

echo
echo "Done. Open the trace with:  open '$TRACE'"
echo "Or dump a summary with:     xcrun xctrace export --input '$TRACE' --toc"
