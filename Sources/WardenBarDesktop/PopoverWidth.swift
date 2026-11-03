import Foundation

/// Non-secret display preference. Validate persisted values before passing them to SwiftUI.
public enum PopoverWidth {
    public static let defaultValue: Double = 320
    public static let minimum: Double = 280
    public static let maximum: Double = 480

    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(maximum, max(minimum, value))
    }

    public static func resized(start: Double, translation: Double) -> Double {
        guard translation.isFinite else { return clamp(start) }
        return clamp(clamp(start) + translation)
    }
}
