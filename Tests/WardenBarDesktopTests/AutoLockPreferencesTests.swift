import Foundation
import XCTest
@testable import WardenBarDesktop

@MainActor
final class AutoLockPreferencesTests: XCTestCase {
    func testDefaultSystemOnlyAndCustomPolicyPersist() throws {
        let suite = "WardenBarPolicyTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AutoLockPreferences(defaults: defaults)
        XCTAssertEqual(preferences.policy, .idle(minutes: 5))
        preferences.policy = .systemOnly
        XCTAssertNil(preferences.policy.timeout)
        XCTAssertEqual(AutoLockPreferences(defaults: defaults).policy, .systemOnly)
        preferences.policy = .idle(minutes: 17)
        XCTAssertEqual(AutoLockPreferences(defaults: defaults).policy.timeout, 1020)
    }

    func testInvalidStorageFallsBackAndAssignedTimesAreBounded() throws {
        let suite = "WardenBarPolicyTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value: Any in [-1, 13, 999999, "invalid"] {
            defaults.set(value, forKey: "autoLockSeconds")
            XCTAssertEqual(AutoLockPreferences(defaults: defaults).policy, .idle(minutes: 5))
        }
        let preferences = AutoLockPreferences(defaults: defaults)
        preferences.policy = .idle(minutes: 0)
        XCTAssertEqual(preferences.policy.timeout, 60)
        preferences.policy = .idle(minutes: Int.max)
        XCTAssertEqual(preferences.policy.timeout, 86400)
    }
}
