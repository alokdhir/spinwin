import AppKit
import ApplicationServices

/// Private helper exported by the HIServices framework that maps an
/// AXUIElement to its CoreGraphics window ID. This is the reliable way to
/// match an accessibility window to a ScreenCaptureKit window; there is no
/// public equivalent. Widely used by window managers (yabai, etc.).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// Moves a specific window off-screen (keeping it live so it can still be
/// captured) and restores it to its original position on request.
final class AccessibilityWindowMover {
    private var movedElement: AXUIElement?
    private var originalPosition: CGPoint?

    /// Human-readable reason the last `hide` call failed, for surfacing to the user.
    private(set) var lastFailure: String?

    /// Prompts for Accessibility permission if not yet granted.
    static func ensureTrusted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Finds the AX window matching `windowID` (falling back to a frame match),
    /// records its position, and moves it off-screen. Returns false if not
    /// found, not settable, or the move was rejected.
    @discardableResult
    func hide(pid: pid_t, windowID: CGWindowID, frame: CGRect) -> Bool {
        lastFailure = nil

        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let listErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard listErr == .success, let windows = windowsValue as? [AXUIElement] else {
            lastFailure = "AXWindows list failed (AXError \(listErr.rawValue)); is Accessibility permission granted?"
            NSLog("RotateWin: \(lastFailure!)")
            return false
        }

        guard let element = matchWindow(in: windows, windowID: windowID, frame: frame) else {
            lastFailure = "No AX window matched id=\(windowID) among \(windows.count) windows (pid \(pid))."
            NSLog("RotateWin: \(lastFailure!)")
            return false
        }

        // Some windows expose position but refuse to have it set.
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable)
        guard settable.boolValue else {
            lastFailure = "This window's position is not settable (not movable)."
            NSLog("RotateWin: \(lastFailure!)")
            return false
        }

        if let pos = position(of: element) {
            originalPosition = pos
        }
        movedElement = element

        // Park it far off the top-left of all displays. Most apps keep
        // rendering an off-screen window, so capture continues.
        let setErr = setPosition(CGPoint(x: -30000, y: -30000), on: element)
        if setErr != .success {
            lastFailure = "Setting off-screen position failed (AXError \(setErr.rawValue))."
            NSLog("RotateWin: \(lastFailure!)")
            movedElement = nil
            return false
        }
        return true
    }

    /// Restores the previously hidden window to its original position.
    func restore() {
        if let element = movedElement, let pos = originalPosition {
            _ = setPosition(pos, on: element)
        }
        movedElement = nil
        originalPosition = nil
    }

    // MARK: - Private

    private func matchWindow(in windows: [AXUIElement], windowID: CGWindowID, frame: CGRect) -> AXUIElement? {
        // Preferred: exact CoreGraphics window-ID match.
        for window in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success, wid == windowID {
                return window
            }
        }
        // Fallback: match by origin + size (handy when the ID lookup fails).
        for window in windows {
            guard let origin = position(of: window), let size = size(of: window) else { continue }
            if abs(origin.x - frame.minX) < 5, abs(origin.y - frame.minY) < 5,
               abs(size.width - frame.width) < 5, abs(size.height - frame.height) < 5 {
                return window
            }
        }
        return nil
    }

    private func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success else {
            return nil
        }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    private func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success else {
            return nil
        }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    private func setPosition(_ point: CGPoint, on element: AXUIElement) -> AXError {
        var mutablePoint = point
        guard let axValue = AXValueCreate(.cgPoint, &mutablePoint) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
    }
}
