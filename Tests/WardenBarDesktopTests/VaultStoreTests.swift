import AppKit
import XCTest
@testable import WardenBarCore
@testable import WardenBarDesktop

actor ControlledVault: VaultBackend {
    var state: VaultState = .locked
    var unlockStarted = false
    var readStarted = false
    private var pauseUnlock = false
    private var pauseRead = false
    private var failLock = false
    private var failSync = false
    private var failFolders = false
    var foldersStarted = false
    private var pauseFolders = false
    private var folderName = "Personal"
    private var foldersWait: CheckedContinuation<Void, Never>?
    private var unlockWait: CheckedContinuation<Void, Never>?
    private var readWait: CheckedContinuation<Void, Never>?
    private var records = [
        VaultItemSummary(id: "one", name: "Café", username: "alice", uris: ["https://example.invalid"], favorite: true, folderID: "folder", hasTOTP: true),
        VaultItemSummary(id: "two", name: "Mail", username: "bob", uris: ["https://mail.invalid"], favorite: false, folderID: nil)
    ]

    func status() -> CLIStatus { state == .unlocked ? .unlocked : .locked }
    func unlock(masterPassword: String) async throws {
        guard masterPassword == "synthetic-master" else { throw CLIProcessError.nonzeroExit(1) }
        state = .unlocked
        unlockStarted = true
        if pauseUnlock { await withCheckedContinuation { unlockWait = $0 } }
    }
    func items() -> [VaultItemSummary] { records }
    func folders() async throws -> [VaultFolder] {
        foldersStarted = true
        if pauseFolders { await withCheckedContinuation { foldersWait = $0 } }
        if failFolders { throw CLIProcessError.nonzeroExit(1) }
        return [VaultFolder(id: "folder", name: folderName)]
    }
    func totp(for id: String) async throws -> SecretValue {
        _ = try await password(for: id)
        return SecretValue("123456")
    }
    func password(for id: String) async throws -> SecretValue {
        guard records.contains(where: { $0.id == id }) else { throw VaultError.itemUnavailable }
        readStarted = true
        if pauseRead { await withCheckedContinuation { readWait = $0 } }
        return SecretValue("synthetic-password")
    }
    func sync() throws { if failSync { throw CLIProcessError.nonzeroExit(8) } }
    func lock() throws {
        state = failLock ? .lockFailed : .locked
        if failLock { throw CLIProcessError.nonzeroExit(9) }
    }
    func delayUnlock() { pauseUnlock = true }
    func delayRead() { pauseRead = true }
    func resumeUnlock() { unlockWait?.resume(); unlockWait = nil }
    func resumeRead() { readWait?.resume(); readWait = nil }
    func rejectLock() { failLock = true }
    func rejectSync() { failSync = true }
    func rejectFolders() { failFolders = true }
    func delayFolders() { pauseFolders = true }
    func resumeFolders() { foldersWait?.resume(); foldersWait = nil }
    func useLongMetadata() {
        folderName = "A very long folder name that must fit inside the compact folder control"
        records = [VaultItemSummary(id: "one", name: "A very long login name that must truncate before the copy actions", username: "long-account-name@example.invalid", uris: [], favorite: true, folderID: "folder", hasTOTP: true)]
    }
}

@MainActor
final class VaultStoreTests: XCTestCase {
    func testLateFoldersCannotRepopulateAfterLock() async throws {
        let backend = ControlledVault()
        await backend.delayFolders()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        let opening = Task { await store.unlock(masterPassword: "synthetic-master") }
        try await waitFor { await backend.foldersStarted }
        await store.lock().value
        await backend.resumeFolders()
        await opening.value
        XCTAssertEqual(store.phase, .locked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.folders.isEmpty)
    }
    func testFolderFiltersIntersectSearchAndFavoritesAndClearOnLock() async {
        let (store, board) = make(ControlledVault())
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        XCTAssertEqual(store.folders.first?.name, "Personal")
        store.folderFilter = .folder("folder")
        XCTAssertEqual(store.filteredItems.map(\.id), ["one"])
        store.query = "bob"
        XCTAssertTrue(store.filteredItems.isEmpty)
        store.query = ""
        store.folderFilter = .unfiled
        XCTAssertEqual(store.filteredItems.map(\.id), ["two"])
        store.favoritesOnly = true
        XCTAssertTrue(store.filteredItems.isEmpty)
        await store.lock().value
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertEqual(store.folderFilter, .all)
    }

    func testFolderReadFailureKeepsLoginListUsable() async {
        let backend = ControlledVault()
        await backend.rejectFolders()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.phase, .unlocked)
        XCTAssertNotNil(store.errorMessage)
        await store.copyPassword(for: "one")
        XCTAssertEqual(board.string(forType: .string), "synthetic-password")
    }

    func testCodeCopyAndUnavailableCodeLeaveClipboardSafe() async {
        let (store, board) = make(ControlledVault())
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        await store.copyTOTP(for: "one")
        XCTAssertEqual(board.string(forType: .string), "123456")
        store.copyUsername(for: "two")
        await store.copyTOTP(for: "two")
        XCTAssertEqual(board.string(forType: .string), "bob")
    }

    func testLateAndQueuedCodesCannotReachClipboardAfterLock() async throws {
        let backend = ControlledVault()
        await backend.delayRead()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        let old = store.generation
        let reading = Task { await store.copyTOTP(for: "one", expectedGeneration: old) }
        try await waitFor { await backend.readStarted }
        await store.lock().value
        await backend.resumeRead()
        await reading.value
        await store.unlock(masterPassword: "synthetic-master")
        await store.copyTOTP(for: "one", expectedGeneration: old)
        XCTAssertNil(board.string(forType: .string))
    }
    private func make(_ backend: ControlledVault) -> (VaultStore, NSPasteboard) {
        let board = NSPasteboard(name: .init("WardenBarStoreTest-" + UUID().uuidString))
        return (VaultStore(backend: backend, clipboard: ClipboardService(pasteboard: board)), board)
    }

    private func waitFor(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Backend operation did not start")
        throw NSError(domain: "ControlledVaultTimeout", code: 1)
    }

    func testSearchMatchesMetadataAndFavoritesInMemory() async {
        let (store, board) = make(ControlledVault())
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        store.query = "cafe alice"
        XCTAssertEqual(store.filteredItems.map(\.id), ["one"])
        store.query = "mail.invalid"
        XCTAssertEqual(store.filteredItems.map(\.id), ["two"])
        store.favoritesOnly = true
        XCTAssertTrue(store.filteredItems.isEmpty)
    }

    func testLockImmediatelyClearsIndexSelectionClipboardAndInputGeneration() async {
        let (store, board) = make(ControlledVault())
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        store.select("one")
        store.copyUsername(for: "one")
        XCTAssertEqual(board.string(forType: .string), "alice")
        let generation = store.generation
        let locking = store.lock()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.selectedItem)
        XCTAssertNil(board.string(forType: .string))
        XCTAssertNotEqual(store.generation, generation)
        await locking.value
        XCTAssertEqual(store.phase, .locked)
    }

    func testLatePasswordNeverReachesClipboardAfterLock() async throws {
        let backend = ControlledVault()
        await backend.delayRead()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        let reading = Task { await store.copyPassword(for: "one") }
        try await waitFor { await backend.readStarted }
        await store.lock().value
        await backend.resumeRead()
        await reading.value
        XCTAssertNil(board.string(forType: .string))
        XCTAssertEqual(store.phase, .locked)
        XCTAssertNil(store.notice)
    }

    func testLateUnlockDoesNotRepopulateMetadataAfterLock() async throws {
        let backend = ControlledVault()
        await backend.delayUnlock()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        let opening = Task { await store.unlock(masterPassword: "synthetic-master") }
        try await waitFor { await backend.unlockStarted }
        await store.lock().value
        await backend.resumeUnlock()
        await opening.value
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.phase, .locked)
    }

    func testLockFailureRemainsVisibleAndRejectsCopies() async {
        let backend = ControlledVault()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        await backend.rejectLock()
        await store.lock().value
        await store.start()
        await store.copyPassword(for: "one")
        XCTAssertEqual(store.phase, .lockFailed)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(board.string(forType: .string))
    }

    func testSyncFailureKeepsExistingMetadataWithoutRawError() async {
        let backend = ControlledVault()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        await backend.rejectSync()
        await store.sync()
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.phase, .unlocked)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.errorMessage!.contains("nonzeroExit"))
    }

    func testSafetyLockWhileAlreadyLockedResetsPartialPasswordForm() async {
        let (store, board) = make(ControlledVault())
        defer { board.releaseGlobally() }
        await store.start()
        let before = store.generation
        await store.lock().value
        XCTAssertNotEqual(store.generation, before)
        XCTAssertEqual(store.phase, .locked)
    }

    func testQueuedUnlockFromBeforeSafetyLockIsRejected() async {
        let backend = ControlledVault()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        let old = store.generation
        await store.lock().value
        await store.unlock(masterPassword: "synthetic-master", expectedGeneration: old)
        let started = await backend.unlockStarted
        XCTAssertFalse(started)
        XCTAssertEqual(store.phase, .locked)
    }

    func testQueuedCopyFromPreviousSessionCannotUseNewSession() async {
        let (store, board) = make(ControlledVault())
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        let old = store.generation
        await store.lock().value
        await store.unlock(masterPassword: "synthetic-master")
        await store.copyPassword(for: "one", expectedGeneration: old)
        XCTAssertNil(board.string(forType: .string))
    }

    func testQuitIsDeniedWhenBackendLockFails() async {
        let backend = ControlledVault()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        await backend.rejectLock()
        let mayQuit = await store.prepareToQuit()
        XCTAssertFalse(mayQuit)
        XCTAssertEqual(store.phase, .lockFailed)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testQuitIsAllowedAfterSuccessfulBackendLock() async {
        let (store, board) = make(ControlledVault())
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        let mayQuit = await store.prepareToQuit()
        XCTAssertTrue(mayQuit)
        XCTAssertEqual(store.phase, .locked)
    }
}
