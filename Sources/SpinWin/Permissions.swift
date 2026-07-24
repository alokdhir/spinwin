import AppKit
import CoreGraphics

/// Requests every system permission SpinWin needs up front (at launch) so the
/// user grants them once, instead of hitting prompts mid-rotation:
///   - Screen Recording: required to capture the window's live contents.
///   - Accessibility: required to move the source window off-screen.
@MainActor
enum Permissions {
    /// Prompts for any not-yet-granted permission. Safe to call every launch:
    /// already-granted permissions never re-prompt.
    static func requestAll() {
        requestScreenRecording()
        // Prompts (and deep-links to System Settings) only if not yet trusted.
        _ = AccessibilityWindowMover.ensureTrusted()
    }

    /// Triggers the Screen Recording prompt the first time; the preflight check
    /// avoids re-asking once it's been granted.
    private static func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }
}
