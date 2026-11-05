import XCTest
@testable import WardenBarDesktop

@MainActor
final class MemoryBiometricCredentials: BiometricCredentials {
    var isAvailable = true
    var records: [String: Data] = [:]
    var rejected = false
    var readWait: CheckedContinuation<Void, Never>?
    var pauseRead = false
    func save(_ password: Data, account: String) async throws { records[account] = password }
    func read(account: String) async throws -> Data {
        if pauseRead { await withCheckedContinuation { readWait = $0 } }
        if rejected { throw QuickUnlockError.biometricUnavailable }
        guard let data = records[account] else { throw QuickUnlockError.notConfigured }
        return data
    }
    func remove(account: String) throws { records[account] = nil }
    func cancel() {}
}

@MainActor
final class QuickUnlockTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WardenBarQuickUnlockTests-" + UUID().uuidString)!
    }

    func testPINRequiresManualMasterUnlockAfterRestart() throws {
        let defaults = makeDefaults()
        let credentials = MemoryBiometricCredentials()
        let first = QuickUnlockController(defaults: defaults, credentials: credentials, profile: "test")
        first.bind(account: "account-a")
        first.recordUnlocked(password: "synthetic-master", manual: true)
        try first.configurePIN("123456", password: "synthetic-master")
        first.revokeAuthorization()
        XCTAssertEqual(try first.passwordForPIN("123456"), "synthetic-master")

        let restarted = QuickUnlockController(defaults: defaults, credentials: credentials, profile: "test")
        restarted.bind(account: "account-a")
        XCTAssertTrue(restarted.pinConfigured)
        XCTAssertFalse(restarted.pinReady)
        restarted.recordUnlocked(password: "synthetic-master", manual: false)
        XCTAssertFalse(restarted.pinReady, "Biometrics must not satisfy the master-password requirement")
        restarted.recordUnlocked(password: "synthetic-master", manual: true)
        XCTAssertEqual(try restarted.passwordForPIN("123456"), "synthetic-master")
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("synthetic-master"))
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("123456"))
    }

    func testWrongPINExhaustionCannotBeResetByLocking() throws {
        let controller = QuickUnlockController(defaults: makeDefaults(), credentials: MemoryBiometricCredentials(), profile: "test")
        controller.bind(account: "a")
        controller.recordUnlocked(password: "synthetic-master", manual: true)
        try controller.configurePIN("012345", password: "synthetic-master")
        for _ in 0..<5 {
            XCTAssertThrowsError(try controller.passwordForPIN("999999"))
            controller.revokeAuthorization()
        }
        XCTAssertFalse(controller.pinReady)
        XCTAssertThrowsError(try controller.passwordForPIN("012345"))
        controller.recordUnlocked(password: "synthetic-master", manual: true)
        XCTAssertEqual(try controller.passwordForPIN("012345"), "synthetic-master")
    }

    func testSetupRejectsWrongPasswordAndNonASCIIPIN() throws {
        let controller = QuickUnlockController(defaults: makeDefaults(), credentials: MemoryBiometricCredentials(), profile: "test")
        controller.bind(account: "a")
        controller.recordUnlocked(password: "synthetic-master", manual: true)
        XCTAssertThrowsError(try controller.configurePIN("123456", password: "wrong"))
        XCTAssertThrowsError(try controller.configurePIN("１２３４５６", password: "synthetic-master"))
        XCTAssertFalse(controller.pinConfigured)
        controller.revokeAuthorization()
        XCTAssertThrowsError(try controller.configurePIN("123456", password: "synthetic-master"))
    }

    func testAccountAndProfileIsolationAndPasswordChange() throws {
        let controller = QuickUnlockController(defaults: makeDefaults(), credentials: MemoryBiometricCredentials(), profile: "test")
        controller.bind(account: "a")
        controller.recordUnlocked(password: "synthetic-master", manual: true)
        try controller.configurePIN("123456", password: "synthetic-master")
        controller.bind(account: "b")
        XCTAssertFalse(controller.pinConfigured)
        XCTAssertThrowsError(try controller.passwordForPIN("123456"))
        controller.bind(account: "a")
        XCTAssertTrue(controller.pinConfigured)
        XCTAssertFalse(controller.pinReady)
        controller.recordUnlocked(password: "changed-master", manual: true)
        XCTAssertFalse(controller.pinConfigured)
    }

    func testBiometricCredentialSurvivesRestartButRequiresAuthentication() async throws {
        let defaults = makeDefaults()
        let credentials = MemoryBiometricCredentials()
        let first = QuickUnlockController(defaults: defaults, credentials: credentials, profile: "test")
        first.bind(account: "a")
        first.recordUnlocked(password: "synthetic-master", manual: true)
        try await first.enableTouchID(password: "synthetic-master")
        let second = QuickUnlockController(defaults: defaults, credentials: credentials, profile: "test")
        second.bind(account: "a")
        XCTAssertTrue(second.touchIDEnabled)
        let recovered = try await second.passwordForTouchID()
        XCTAssertEqual(recovered, "synthetic-master")
        credentials.rejected = true
        do { _ = try await second.passwordForTouchID(); XCTFail("Denied biometric approval must fail closed") }
        catch {}
        try second.disableTouchID()
        XCTAssertFalse(second.touchIDEnabled)
    }

    func testLateBiometricResultIsRejectedAfterLock() async throws {
        let credentials = MemoryBiometricCredentials()
        let controller = QuickUnlockController(defaults: makeDefaults(), credentials: credentials, profile: "test")
        controller.bind(account: "a")
        controller.recordUnlocked(password: "synthetic-master", manual: true)
        try await controller.enableTouchID(password: "synthetic-master")
        credentials.pauseRead = true
        let pending = Task { try await controller.passwordForTouchID() }
        while credentials.readWait == nil { await Task.yield() }
        controller.revokeAuthorization()
        credentials.readWait?.resume()
        do { _ = try await pending.value; XCTFail("A stale approval must not return a password") }
        catch {}
    }

    func testSuccessfulPINResetsConsecutiveFailureCount() throws {
        let controller = QuickUnlockController(defaults: makeDefaults(), credentials: MemoryBiometricCredentials(), profile: "test")
        controller.bind(account: "a")
        controller.recordUnlocked(password: "synthetic-master", manual: true)
        try controller.configurePIN("123456", password: "synthetic-master")
        for _ in 0..<4 { XCTAssertThrowsError(try controller.passwordForPIN("999999")) }
        _ = try controller.passwordForPIN("123456")
        XCTAssertThrowsError(try controller.passwordForPIN("999999"))
        XCTAssertTrue(controller.pinReady)
    }
}
