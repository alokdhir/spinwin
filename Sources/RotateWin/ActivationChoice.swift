import Foundation

/// How rotation should be applied the moment a window is picked: a fixed
/// preset angle, or free/manual rotation via a drag handle on the overlay.
enum ActivationChoice: Equatable {
    case angle(Double)
    case free

    static let presets: [ActivationChoice] = [.angle(90), .angle(180), .angle(270), .free]

    /// The angle to start the session at. Free starts at 0° and is adjusted
    /// by dragging the overlay's rotation handle.
    var initialDegrees: Double {
        switch self {
        case .angle(let degrees): return degrees
        case .free: return 0
        }
    }

    var label: String {
        switch self {
        case .angle(let degrees): return "\(Int(degrees))°"
        case .free: return "Free"
        }
    }

    var tooltip: String {
        switch self {
        case .angle(let degrees): return "Rotate to \(Int(degrees))°"
        case .free: return "Free rotation — drag the handle to set any angle"
        }
    }

    /// SF Symbol used for the free-rotation option.
    var symbolName: String { "arrow.2.circlepath" }

    private var storageKey: String {
        switch self {
        case .angle(let degrees): return "\(Int(degrees))"
        case .free: return "free"
        }
    }

    private static func choice(forStorageKey key: String) -> ActivationChoice {
        if key == "free" { return .free }
        if let degrees = Double(key) { return .angle(degrees) }
        return .angle(180)
    }

    /// The last choice the user made, persisted across launches. Defaults to
    /// 180° (the tool's original behavior) the first time.
    static var lastUsed: ActivationChoice {
        get { choice(forStorageKey: UserDefaults.standard.string(forKey: defaultsKey) ?? "180") }
        set { UserDefaults.standard.set(newValue.storageKey, forKey: defaultsKey) }
    }

    private static let defaultsKey = "RotateWin.lastActivationChoice"
}
