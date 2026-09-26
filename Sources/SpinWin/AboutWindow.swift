import AppKit

/// A small About window: an enlarged menubar icon, the app name and version,
/// the author, and a link to the GitHub repository.
@MainActor
final class AboutWindow: NSWindow {
    static let repositoryURL = URL(string: "https://github.com/alokdhir/spinwin")!
    static let author = "Alok K. Dhir"

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "About SpinWin"
        isReleasedWhenClosed = false
        contentView = Self.makeContent()
        center()
    }

    /// Brings the window forward. SpinWin is an accessory app with no Dock
    /// icon, so it has to activate itself or the window opens behind others.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private static func makeContent() -> NSView {
        // Scaled up from the menubar defaults (18/12/1.6) so it reads as the
        // same mark. As a template image, the image view tints it to match
        // the current light/dark appearance.
        let icon = NSImageView(image: MenuBarIcon.make(canvasSize: 96, squareSide: 64, lineWidth: 6))
        icon.contentTintColor = .labelColor

        let name = NSTextField(labelWithString: "SpinWin")
        name.font = .systemFont(ofSize: 20, weight: .semibold)

        let version = NSTextField(labelWithString: versionText)
        version.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        version.textColor = .secondaryLabelColor

        let author = NSTextField(labelWithString: "by \(Self.author)")

        let link = NSTextField(labelWithAttributedString: NSAttributedString(
            string: repositoryURL.absoluteString.replacingOccurrences(of: "https://", with: ""),
            attributes: [.link: repositoryURL, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ))
        // Links in a label are only clickable when it's selectable.
        link.isSelectable = true
        link.allowsEditingTextAttributes = true

        let stack = NSStackView(views: [icon, name, version, author, link])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(12, after: version)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        return stack
    }

    private static var versionText: String {
        // `swift run` has no bundle Info.plist, so there's no version to show.
        guard let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "Development build"
        }
        return "Version \(short)"
    }
}
