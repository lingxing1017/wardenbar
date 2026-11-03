import AppKit
import Foundation

@MainActor
public final class SecurityMonitor {
    private let workspace: NotificationCenter
    private let distributed: NotificationCenter
    private let clock: () -> TimeInterval
    private let lastActivity: () -> TimeInterval
    private let isUnlocked: () -> Bool
    private let onLock: () -> Void
    private let policy: () -> AutoLockPolicy
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?

    public init(
        workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributed: NotificationCenter = DistributedNotificationCenter.default(),
        policy: @escaping () -> AutoLockPolicy = { .idle(minutes: 5) },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        lastActivity: @escaping () -> TimeInterval,
        isUnlocked: @escaping () -> Bool,
        onLock: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.distributed = distributed
        self.policy = policy
        self.clock = clock
        self.lastActivity = lastActivity
        self.isUnlocked = isUnlocked
        self.onLock = onLock
    }

    public func start() {
        guard timer == nil else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name)
        }
        // Best effort supplemental notification, not a documented Apple compatibility contract.
        observe(distributed, .init("com.apple.screenIsLocked"))
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func checkIdle() {
        guard let timeout = policy().timeout else { return }
        if isUnlocked(), clock() - lastActivity() >= timeout { onLock() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onLock() }
        }
        observers.append((center, token))
    }

    deinit {
        timer?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
    }
}
