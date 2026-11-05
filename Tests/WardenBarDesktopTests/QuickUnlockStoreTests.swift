import AppKit
import XCTest
@testable import WardenBarDesktop

@MainActor
final class QuickUnlockStoreTests: XCTestCase {
    func testPINUsesRealBackendUnlockAndCannotBypassLockFailure() async throws {
        let quick = QuickUnlockController(defaults: UserDefaults(suiteName: "QuickStore-" + UUID().uuidString)!,
                                          credentials: MemoryBiometricCredentials(), profile: "test")
        let backend = ControlledVault()
        let board = NSPasteboard(name: .init("QuickStore-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = VaultStore(backend: backend, clipboard: ClipboardService(pasteboard: board), quickUnlock: quick)
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        try quick.configurePIN("123456", password: "synthetic-master")
        await store.lock().value
        await store.unlockWithPIN("999999")
        XCTAssertEqual(store.phase, .locked)
        XCTAssertTrue(store.items.isEmpty)
        await store.unlockWithPIN("123456")
        XCTAssertEqual(store.phase, .unlocked)
        XCTAssertFalse(store.items.isEmpty)
        await backend.rejectLock()
        await store.lock().value
        await store.unlockWithPIN("123456")
        XCTAssertEqual(store.phase, .lockFailed)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testLockPreemptsPendingTouchIDApproval() async throws {
        let credentials = MemoryBiometricCredentials()
        let quick = QuickUnlockController(defaults: UserDefaults(suiteName: "QuickStore-" + UUID().uuidString)!,
                                          credentials: credentials, profile: "test")
        let backend = ControlledVault()
        let board = NSPasteboard(name: .init("QuickStore-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = VaultStore(backend: backend, clipboard: ClipboardService(pasteboard: board), quickUnlock: quick)
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        try await quick.enableTouchID(password: "synthetic-master")
        await store.lock().value
        credentials.pauseRead = true
        let opening = Task { await store.unlockWithTouchID() }
        while credentials.readWait == nil { await Task.yield() }
        await store.lock().value
        credentials.readWait?.resume()
        await opening.value
        XCTAssertEqual(store.phase, .locked)
        XCTAssertTrue(store.items.isEmpty)
    }
}
