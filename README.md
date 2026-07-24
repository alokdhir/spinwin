# RotateWin

A macOS menubar utility that visually rotates a selected window by any angle
(90° increments, arbitrary angles, or a continuous spin).

## How it works (and why)

macOS has **no public API to rotate another app's window**. Real rotation
would require private SkyLight calls (`CGSSetWindowTransform`) with System
Integrity Protection disabled — not worth it.

Instead, RotateWin fakes it:

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

```sh
./scripts/build-app.sh          # builds RotateWin.app (release)
open RotateWin.app              # grant Screen Recording + Accessibility
```

For quick iteration during development:

```sh
swift build && swift run RotateWin
```

Click the menubar icon → pick a rotation (or spin speed) → pick a window.
Drag the rotated overlay anywhere to reposition it. "Stop rotating" restores
the original window.

## Permissions

- **Screen Recording** — to capture the window contents.
- **Accessibility** — to move the source window off-screen and restore it.

## Current limitations

- **Input is not remapped yet.** The overlay is a live picture you can drag,
  but clicks/keys are not forwarded through the rotation to the real window.
  (Planned: `CGEvent.postToPid` with inverse-rotation coordinate mapping.)
- **Mission Control / Exposé leak.** The hidden window is parked off-screen but
  still a real window, so Exposé shows it *unrotated*. There is no public API
  to exclude another app's window from Mission Control, and minimizing it would
  stop the capture.
- Some apps throttle rendering of off-screen windows, which can slow the feed.

## Layout

| File | Role |
| --- | --- |
| `main.swift` | App entry point (accessory/menubar policy) |
| `AppDelegate.swift` | Menubar item, menu, window list |
| `RotationController.swift` | Orchestrates hide → capture → overlay |
| `CaptureEngine.swift` | ScreenCaptureKit stream → CGImage frames |
| `OverlayWindow.swift` | Transparent rotating/spinning overlay, drag |
| `AccessibilityWindowMover.swift` | Move source window off-screen + restore |
