import Foundation

/// How rotation should be applied the moment a window is picked: a fixed
/// preset angle, a continuous spin at a preset speed, or free/manual
/// rotation via a drag handle on the overlay.
enum ActivationChoice: Equatable {
    case angle(Double)
    case spin(rpm: Double)
    case free

    static let anglePresets: [ActivationChoice] = [.angle(90), .angle(180), .angle(270)]
    static let spinPresets: [ActivationChoice] = [.spin(rpm: 6), .spin(rpm: 15), .spin(rpm: 30)]
    static let presets: [ActivationChoice] = anglePresets + spinPresets + [.free]

    /// The angle to start the session at. Spin and free both start at 0°;
    /// spin then animates continuously, free is adjusted via the handle.
    var initialDegrees: Double {
        switch self {
        case .angle(let degrees): return degrees
        case .spin, .free: return 0
        }
    }

    var initialSpinning: Bool {
        if case .spin = self { return true }
        return false
    }

    var initialRPM: Double {
        if case .spin(let rpm) = self { return rpm }
        return 15
    }

    var label: String {
        switch self {
        case .angle(let degrees): return "\(Int(degrees))°"
        case .spin(let rpm): return "\(Int(rpm))"
        case .free: return "Free"
        }
    }

    var tooltip: String {
        switch self {
        case .angle(let degrees): return "Rotate to \(Int(degrees))°"
        case .spin(let rpm): return "Spin continuously at \(Int(rpm)) rpm"
        case .free: return "Free rotation — drag the handle to set any angle"
        }
    }

    /// SF Symbol shown alongside the label, if any (plain angles are text-only).
    var symbolName: String? {
        switch self {
        case .angle: return nil
        case .spin: return "arrow.triangle.2.circlepath"
        case .free: return "arrow.2.circlepath"
        }
    }

    private var storageKey: String {
        switch self {
        case .angle(let degrees): return "\(Int(degrees))"
        case .spin(let rpm): return "spin\(Int(rpm))"
        case .free: return "free"
        }
    }

    private static func choice(forStorageKey key: String) -> ActivationChoice {
        if key == "free" { return .free }
        if key.hasPrefix("spin"), let rpm = Double(key.dropFirst("spin".count)) { return .spin(rpm: rpm) }
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
