import AppKit
import XCTest
@testable import WardenBarDesktop

@MainActor
final class SecurityMonitorTests: XCTestCase {
    func testIdleThresholdUsesVaultActivityAndOnlyMonitorsUnlockedState() {
        var now: TimeInterval = 300
        var activity: TimeInterval = 0
        var unlocked = true
        var locks = 0
        let monitor = SecurityMonitor(
            clock: { now }, lastActivity: { activity }, isUnlocked: { unlocked }, onLock: { locks += 1 }
        )
        monitor.checkIdle()
        XCTAssertEqual(locks, 1)
        activity = 250
        monitor.checkIdle()
        XCTAssertEqual(locks, 1)
        now = 600
        unlocked = false
        monitor.checkIdle()
        XCTAssertEqual(locks, 1)
    }

    func testSystemEventsTriggerImmediateLockAndStopRemovesObservers() {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        var locks = 0
        let monitor = SecurityMonitor(
            workspace: workspace, distributed: distributed,
            lastActivity: { 0 }, isUnlocked: { false }, onLock: { locks += 1 }
        )
        monitor.start()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.post(name: name, object: nil)
        }
        distributed.post(name: .init("com.apple.screenIsLocked"), object: nil)
        XCTAssertEqual(locks, 4)
        monitor.stop()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(locks, 4)
    }
}
