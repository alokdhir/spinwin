import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
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
        }

        let menu = NSMenu()
        statusItem.menu = menu
        rebuildMenu()

        // Refresh when a session stops on its own (e.g. system "Stop Sharing").
        manager.onStateChange = { [weak self] in self?.rebuildMenu() }

        // Ask for Screen Recording + Accessibility now, so the user isn't
        // interrupted by prompts the first time they rotate a window.
        Permissions.requestAll()
    }

    // MARK: - Menu construction

    fileprivate func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
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
            item.state = (!session.spinning && session.degrees == degrees) ? .on : .off
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
