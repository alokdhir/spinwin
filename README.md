# SpinWin

A macOS menubar utility that visually rotates a selected window by any angle
(90° increments, arbitrary angles, or a continuous spin).

## How it works (and why)

macOS has **no public API to rotate another app's window**. Real rotation
would require private SkyLight calls (`CGSSetWindowTransform`) with System
Integrity Protection disabled — not worth it.

Instead, SpinWin fakes it:

1. **Hide** the selected window off-screen via the Accessibility API. It keeps
   rendering there, so it can still be captured.
2. **Capture** its contents continuously with ScreenCaptureKit
   (`SCStream` + `desktopIndependentWindow` filter) — this grabs only that
   window's buffer, so the overlay never mirrors itself.
3. **Draw** the frames in a transparent, borderless overlay window placed where
   the original was, rotated with a `CALayer` transform.

Because it's a layer transform, any angle works — the overlay is sized to the
rotated content's bounding box so nothing clips, and a diagonal-sized square is
used while spinning.

## Usage

The easiest way to get SpinWin is the [latest release](https://github.com/alokdhir/spinwin/releases/latest)
— the download is signed with a Developer ID and notarized by Apple, so it
launches without Gatekeeper warnings. Or build it yourself:

```sh
./scripts/build-app.sh          # builds SpinWin.app (release)
open SpinWin.app              # grant Screen Recording + Accessibility
```

For quick iteration during development:

```sh
swift build && swift run SpinWin
```

**Left-click** the menubar icon to start: choose a rotation in the bottom
options bar (a preset angle, a spin speed + direction, or free rotation), then
click the window you want. Drag the overlay to reposition it; drag its handle
to rotate freely. Press **Esc** on the overlay to stop and restore the window.

**Right-click** (or Control-click) the icon for the menu: active rotations
(with per-window angle/spin controls), Stop all, and Quit.

## Permissions

- **Screen Recording** — to capture the window contents.
- **Accessibility** — to move the source window off-screen and restore it.

## Current limitations

- **The overlay is a live picture, not interactive.** You can drag and rotate
  it, but clicks and keystrokes are not sent to the real window underneath.
- **Mission Control / Exposé leak.** The hidden window is parked off-screen but
  still a real window, so Exposé shows it *unrotated*. There is no public API
  to exclude another app's window from Mission Control, and minimizing it would
  stop the capture.
- Some apps throttle rendering of off-screen windows, which can slow the feed.
- **A window that resizes itself while rotated keeps its original footprint.**
  You can't drag-resize the hidden window, but an app can still resize it on its
  own (a video player adapting to a new track, a terminal responding to an escape
  sequence). The capture is letterboxed into the original size until you stop and
  rotate it again.

## Layout

| File | Role |
| --- | --- |
| `main.swift` | App entry point (accessory/menubar policy) |
| `AppDelegate.swift` | Menubar item; left-click rotates, right-click opens menu |
| `Permissions.swift` | Requests Screen Recording + Accessibility at launch |
| `WindowPicker.swift` | Full-screen window picker + rotation options bar |
| `RotationManager.swift` | Tracks one rotation session per window |
| `RotationSession.swift` | Orchestrates hide → capture → overlay per window |
| `CaptureEngine.swift` | ScreenCaptureKit stream → IOSurface frames |
| `OverlayWindow.swift` | Transparent rotating/spinning overlay, drag |
| `AccessibilityWindowMover.swift` | Move source window off-screen + restore |
| `ActivationChoice.swift` | Initial rotation choice (angle/spin/free) |
| `SpinDirection.swift` | Clockwise/counterclockwise spin option |
| `MenuBarIcon.swift` | Draws the menubar icon |
