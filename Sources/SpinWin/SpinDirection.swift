import Foundation

/// Which way a continuous spin turns.
enum SpinDirection: String {
    case clockwise
    case counterClockwise

    mutating func toggle() {
        self = (self == .clockwise) ? .counterClockwise : .clockwise
    }

    /// Multiplier applied to the rotation animation's angular delta. Positive
    /// z-rotation is counterclockwise in our (non-flipped, y-up) layer space,
    /// so clockwise needs the negated sign.
    var signedTurn: CGFloat { self == .clockwise ? -1 : 1 }

    var symbolName: String { self == .clockwise ? "arrow.clockwise" : "arrow.counterclockwise" }

    var tooltip: String {
        self == .clockwise
            ? "Spinning clockwise — click to reverse"
            : "Spinning counterclockwise — click to reverse"
    }

    /// The last direction chosen, persisted across launches. Clockwise by
    /// default.
    static var lastUsed: SpinDirection {
        get { SpinDirection(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .clockwise }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    private static let defaultsKey = "SpinWin.spinDirection"
}
