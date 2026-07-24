import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menubar-only utility: no Dock icon, no main window.
    app.setActivationPolicy(.accessory)
    app.run()
}
