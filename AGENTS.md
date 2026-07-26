# AGENTS.md

SpinWin is a macOS 14+ menubar utility (Swift Package Manager, no Xcode
project) that *fakes* rotating another app's window, since macOS has no public
API to actually rotate one. Understand the illusion below before changing
anything — most of the code exists to sustain it.

## Commands

```sh
swift build && swift run SpinWin   # fast dev iteration (runs as loose binary)
./scripts/build-app.sh [release]     # build the signed SpinWin.app bundle
open SpinWin.app                   # run bundled; grant permissions when prompted
```

There are no tests, linters, or CI. `swift build` is the only correctness gate.

## The core illusion (read before editing)

A "rotation" is not a real rotation. For each rotated window a `RotationSession`:

1. **Hides** the real window by parking it just past the bottom-right corner of
   the union of all displays via the Accessibility API
   (`AccessibilityWindowMover.offScreenTarget`). It stays live off-screen so it
   keeps rendering. Don't change that parking spot to a far-away coordinate like
   `(-30000, -30000)`: macOS clamps window positions to keep part of a window
   reachable, and that clamp is much tighter up/left, snapping the window back
   and leaving a visible sliver beside its own overlay. Bottom-right clamps to a
   single corner pixel. `repark()` re-applies it on display changes, since the
   union shrinks when a screen is removed or resized.
2. **Captures** its live contents with ScreenCaptureKit
   (`CaptureEngine`, `SCContentFilter(desktopIndependentWindow:)`) — this grabs
   only that window's buffer, which is *why* the overlay never mirrors itself.
3. **Draws** each frame in a transparent borderless `OverlayWindow` placed where
   the original was, rotated via a `CALayer` transform.

Breaking any step breaks the illusion: e.g. minimizing the source window stops
capture; a normal overlay window would capture itself into an infinite mirror.

## Architecture / data flow

- `main.swift` — entry point; `.accessory` activation policy (no Dock icon).
- `AppDelegate` — owns the `NSStatusItem` menu; rebuilds it on every state
  change via `manager.onStateChange`. Menu actions carry the target
  `RotationSession` in `NSMenuItem.representedObject`.
- `RotationManager` — holds `[RotationSession]`, one per window
  (deduped by `windowID`); supports multiple simultaneous rotations.
- `RotationSession` — orchestrates hide → capture → overlay for one window;
  owns its `CaptureEngine`, `AccessibilityWindowMover`, and `OverlayWindow`.
- `CaptureEngine` — `SCStream` → IOSurface frames delivered to the main actor.
- `OverlayWindow` — the transparent rotating/spinning layer host; draggable.
- `WindowPicker` — full-screen shield-level picker (like the screenshot tool).

`SCWindow` is the currency object passed picker → manager → session → capture.

## Non-obvious gotchas

- **Coordinate flips are everywhere.** ScreenCaptureKit/CoreGraphics use a
  top-left origin; Cocoa (`NSWindow`, `NSScreen`) uses bottom-left. Conversions
  use `primaryHeight - y`, where `primaryHeight` is the height of the screen
  whose `frame.origin == .zero` (see `RotationSession.start`,
  `WindowPicker.windowUnderCursor`, `viewRect(for:)`). Match this pattern.
- **`_AXUIElementGetWindow` is a private API** pulled in via `@_silgen_name` in
  `AccessibilityWindowMover`. It's the only reliable way to map an
  `AXUIElement` to a `CGWindowID`. There's a frame-based fallback match.
- **Overlay geometry must fit the rotated content.** Fixed angles size the box
  to the rotated bounding box; spinning uses a diagonal-sized *square* so
  nothing clips mid-spin (`OverlayWindow.setFixed` / `startSpin`).
- **IOSurface lifetime is deliberate.** `CaptureEngine` retains the pixel buffer
  across the hop to main so its backing surface stays valid until CoreAnimation
  takes it — don't "simplify" that retain.
- **Two independent stop paths.** The system "Stop Sharing" control fires
  `CaptureEngine.onStop`; Escape on the overlay fires `OverlayWindow.onEscape`.
  Both route through `RotationSession.onExternalStop` so the manager/menu stay
  in sync. Preserve both.
- **Code signing controls permission persistence.** `build-app.sh` signs with a
  stable Developer ID/Apple Development identity (with `--timestamp=none`).
  Ad-hoc signatures change every build, making macOS re-prompt for Screen
  Recording + Accessibility endlessly. This is intentional; don't revert to
  plain ad-hoc signing.

## Task tracking (Trekker)

This project tracks work in Trekker (`.trekker/trekker.db`), not GitHub Issues
or a TODO file.

```sh
trekker --toon task list --status in_progress   # resume work
trekker --toon task list --status todo          # see backlog
trekker task show <id>                          # full description
trekker comment list <id>                       # prior agent notes
trekker task update <id> -s in_progress
trekker comment add <id> -a "agent" -c "Summary: ..."
trekker task update <id> -s completed
```

Run `trekker quickstart` for the full command reference and workflow. Add a
comment before marking a task complete, and add a checkpoint comment before
a context reset if work is unfinished.

## Permissions

Requires **Screen Recording** (capture) and **Accessibility** (move the source
window). `AccessibilityWindowMover.ensureTrusted()` prompts for the latter.

## Conventions

- All UI/session types are `@MainActor`; `CaptureEngine` runs its `SCStream`
  callbacks on a private queue and hops to main before touching UI.
- Failures surface as human-readable strings (`RotationSession.start` returns
  `String?`; `AccessibilityWindowMover.lastFailure`) and via `NSLog("SpinWin: …")`.
- Keep the `README.md` layout table accurate if you add/rename files (it
  currently lists a stale `RotationController.swift`; the real orchestrators are
  `RotationManager.swift` + `RotationSession.swift`).

## Known limitations (by design, not bugs to "fix")

- Input (clicks/keys) is **not** forwarded to the real window; the overlay is
  display-only by design.
- The hidden source window still appears (unrotated) in Mission Control/Exposé;
  no public API excludes another app's window from it.
