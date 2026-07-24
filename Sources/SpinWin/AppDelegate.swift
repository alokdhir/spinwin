import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let manager = RotationManager()
    private let picker = WindowPicker()

    private let anglePresets: [Double] = [0, 90, 180, 270]
    private let spinPresets: [Double] = [6, 15, 30]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let icon = MenuBarIcon.make()
            icon.accessibilityDescription = "SpinWin"
            button.image = icon
            // Left click rotates immediately; right click opens the menu.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        rebuildMenu()

        // Refresh when a session stops on its own (e.g. system "Stop Sharing").
        manager.onStateChange = { [weak self] in self?.rebuildMenu() }

        // Ask for Screen Recording + Accessibility now, so the user isn't
        // interrupted by prompts the first time they rotate a window.
        Permissions.requestAll()
    }

    /// Rotated windows are parked far off-screen, so they MUST be put back
    /// before we exit. Quitting via the menu goes through `quit()`, but logout,
    /// restart, and `terminate` from anywhere else land here instead — without
    /// this the user is left with windows they can't see or recover.
    func applicationWillTerminate(_ notification: Notification) {
        manager.stopAll()
    }

    // MARK: - Status item click

    /// Left click jumps straight to picking a window; right click (or
    /// Control-click) pops up the menu of active rotations and Quit.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            popUpMenu()
        } else {
            pickWindow()
        }
    }

    /// Shows the menu under the status item, then detaches it so the next
    /// left click still triggers the action instead of reopening the menu.
    private func popUpMenu() {
        rebuildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Menu construction

    fileprivate func rebuildMenu() {
        menu.removeAllItems()

        let pick = NSMenuItem(
            title: "Rotate a window…",
            action: #selector(pickWindow),
            keyEquivalent: ""
        )
        pick.target = self
        menu.addItem(pick)

        if !manager.isEmpty {
            menu.addItem(.separator())
            addHeader("Rotating now", to: menu)
            for session in manager.sessions {
                let item = NSMenuItem(title: session.title, action: nil, keyEquivalent: "")
                item.submenu = sessionSubmenu(for: session)
                menu.addItem(item)
            }

            menu.addItem(.separator())
            let stopAll = NSMenuItem(title: "Stop all", action: #selector(stopAll), keyEquivalent: "")
            stopAll.target = self
            menu.addItem(stopAll)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    /// Per-window controls: angle presets, spin speeds, and stop.
    private func sessionSubmenu(for session: RotationSession) -> NSMenu {
        let submenu = NSMenu()

        addHeader("Rotation", to: submenu)
        for degrees in anglePresets {
            let item = NSMenuItem(title: "\(Int(degrees))°", action: #selector(selectAngle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(degrees)
            item.representedObject = session
            item.state = (!session.spinning && Self.angle(session.degrees, matches: degrees)) ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        addHeader("Spin", to: submenu)
        for rpm in spinPresets {
            let item = NSMenuItem(title: "\(Int(rpm)) rpm", action: #selector(selectSpin(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(rpm)
            item.representedObject = session
            item.state = (session.spinning && session.rpm == rpm) ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        let stop = NSMenuItem(title: "Stop", action: #selector(stopSession(_:)), keyEquivalent: "")
        stop.target = self
        stop.representedObject = session
        submenu.addItem(stop)
        return submenu
    }

    private func addHeader(_ title: String, to menu: NSMenu) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
    }

    /// Whether a session's current angle should read as "at" a preset. Free
    /// rotation produces unrounded, unwrapped values (-90.0000001 for what the
    /// user sees as 270°), so exact equality would leave every preset unchecked
    /// even when the window is visually sitting on one.
    private static func angle(_ degrees: Double, matches preset: Double) -> Bool {
        func normalized(_ value: Double) -> Double {
            let wrapped = value.truncatingRemainder(dividingBy: 360)
            return wrapped < 0 ? wrapped + 360 : wrapped
        }
        let delta = abs(normalized(degrees) - normalized(preset))
        return min(delta, 360 - delta) < 0.5
    }

    // MARK: - Actions

    @objc private func selectAngle(_ sender: NSMenuItem) {
        (sender.representedObject as? RotationSession)?.setFixed(degrees: Double(sender.tag))
        rebuildMenu()
    }

    @objc private func selectSpin(_ sender: NSMenuItem) {
        (sender.representedObject as? RotationSession)?.setSpin(rpm: Double(sender.tag))
        rebuildMenu()
    }

    @objc private func pickWindow() {
        picker.begin { [weak self] window, choice, direction in
            guard let self, let window else { return }
            self.manager.rotate(window: window, choice: choice, direction: direction)
        }
    }

    @objc private func stopSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? RotationSession else { return }
        manager.stop(session)
    }

    @objc private func stopAll() {
        manager.stopAll()
    }

    @objc private func quit() {
        manager.stopAll()
        NSApp.terminate(nil)
    }
}
