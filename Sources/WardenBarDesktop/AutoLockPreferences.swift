import Combine
import Foundation

public enum AutoLockPolicy: Equatable, Sendable {
    case idle(minutes: Int)
    case systemOnly

    public var normalized: Self {
        if case .idle(let minutes) = self { return .idle(minutes: min(1440, max(1, minutes))) }
        return self
    }

    public var timeout: TimeInterval? {
        if case .idle(let minutes) = normalized { return TimeInterval(minutes * 60) }
        return nil
    }
}

@MainActor
public final class AutoLockPreferences: ObservableObject {
    @Published private var storedPolicy: AutoLockPolicy
    public var policy: AutoLockPolicy {
        get { storedPolicy }
        set {
            storedPolicy = newValue.normalized
            defaults.set(Int(storedPolicy.timeout ?? 0), forKey: Self.key)
        }
    }
    private let defaults: UserDefaults
    private static let key = "autoLockSeconds"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let seconds = defaults.object(forKey: Self.key) as? Int,
           seconds >= 0, seconds <= 86400, seconds % 60 == 0 {
            storedPolicy = seconds == 0 ? .systemOnly : .idle(minutes: seconds / 60)
        } else {
            storedPolicy = .idle(minutes: 5)
        }
    }
}
