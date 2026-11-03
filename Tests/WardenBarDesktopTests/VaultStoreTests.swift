import AppKit
import XCTest
@testable import WardenBarCore
@testable import WardenBarDesktop

actor ControlledVault: VaultBackend {
    var state: VaultState = .locked
    var unlockStarted = false
    var readStarted = false
    var syncCalls = 0
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
    func details(for id: String) async throws -> [VaultDetailField] {
        _ = try await password(for: id)
        let kind = records.first(where: { $0.id == id })?.type ?? .login
        let values: [(String, String, String, Bool)]
        switch kind {
        case .card: values = [("card.number", "卡号", "4111111111111111", true), ("card.code", "安全码", "987", true)]
        case .identity: values = [("identity.email", "电子邮箱", "synthetic@example.invalid", false), ("identity.ssn", "社会保障号码", "synthetic-ssn", true)]
        case .secureNote: values = [("notes", "笔记", " synthetic note\nsecond line\n", true)]
        case .sshKey: values = [("ssh.publicKey", "公钥", "ssh-ed25519 synthetic", false), ("ssh.privateKey", "私钥", "\nPRIVATE synthetic\nKEY\n", true)]
        case .login: values = [("login.username", "用户名", "alice", false), ("login.password", "密码", "synthetic-password", true), ("custom:0", "PIN", " synthetic-pin ", true)]
        }
        return values.map { VaultDetailField(id: $0.0, label: $0.1, value: SecretValue($0.2), concealed: $0.3, multiline: kind == .secureNote || kind == .sshKey) }
    }
    func fieldValue(for id: String, fieldID: String) async throws -> SecretValue {
        guard let value = try await details(for: id).first(where: { $0.id == fieldID })?.value else { throw VaultError.itemUnavailable }
        return value
    }
    func sync() throws { syncCalls += 1; if failSync { throw CLIProcessError.nonzeroExit(8) } }
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
    func useMixedRecords() {
        records += [
            VaultItemSummary(id: "card", name: "Synthetic Visa", username: nil, uris: [], favorite: false, folderID: "folder", hasPassword: false, type: .card, subtitle: "Visa · ••••1111", primaryFieldID: "card.number"),
            VaultItemSummary(id: "identity", name: "Synthetic identity", username: nil, uris: [], favorite: false, folderID: nil, hasPassword: false, type: .identity, subtitle: "synthetic@example.invalid", primaryFieldID: "identity.email"),
            VaultItemSummary(id: "note", name: "Synthetic note", username: nil, uris: [], favorite: false, folderID: nil, hasPassword: false, type: .secureNote, primaryFieldID: "notes"),
            VaultItemSummary(id: "ssh", name: "Synthetic SSH", username: nil, uris: [], favorite: false, folderID: nil, hasPassword: false, type: .sshKey, subtitle: "SHA256:synthetic", primaryFieldID: "ssh.publicKey")
        ]
    }
}

@MainActor
final class VaultStoreTests: XCTestCase {
    func testTypesIntersectFolderAndMetadataSearchAndResetOnLock() async {
        let backend = ControlledVault()
        await backend.useMixedRecords()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        store.typeFilter = .card
        store.query = "Visa 1111"
        XCTAssertEqual(store.filteredItems.map(\.id), ["card"])
        store.folderFilter = .unfiled
        XCTAssertTrue(store.filteredItems.isEmpty)
        store.folderFilter = .all
        store.typeFilter = .sshKey
        store.query = "SHA256"
        XCTAssertEqual(store.filteredItems.map(\.id), ["ssh"])
        await store.lock().value
        XCTAssertNil(store.typeFilter)
    }

    func testGenericCopiesPreserveValuesAndRejectQueuedActionsAfterSync() async {
        let (store, board) = make(ControlledVault())
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        await store.copyField(for: "one", fieldID: "custom:0")
        XCTAssertEqual(board.string(forType: .string), " synthetic-pin ")
        let old = store.generation
        board.clearContents()
        await store.sync()
        await store.copyField(for: "one", fieldID: "custom:0", expectedGeneration: old)
        XCTAssertNil(board.string(forType: .string))
    }

    func testLateSelectedDetailResultsAreDiscardedAfterLock() async throws {
        let backend = ControlledVault()
        await backend.delayRead()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        store.select("one")
        let token = store.generation
        let revision = store.indexRevision
        let loading = Task { await store.details(for: "one", expectedGeneration: token, expectedRevision: revision) }
        try await waitFor { await backend.readStarted }
        await store.lock().value
        await backend.resumeRead()
        let details = await loading.value
        XCTAssertNil(details)
    }

    func testLateGenericCopyCannotReachClipboardAfterLock() async throws {
        let backend = ControlledVault()
        await backend.delayRead()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        let copying = Task { await store.copyField(for: "one", fieldID: "login.password") }
        try await waitFor { await backend.readStarted }
        await store.lock().value
        await backend.resumeRead()
        await copying.value
        XCTAssertNil(board.string(forType: .string))
    }
    func testCountdownUsesVaultActivityAndResetsOnInteraction() async {
        var now: TimeInterval = 100
        let board = NSPasteboard(name: .init("WardenBarCountdown-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let store = VaultStore(backend: ControlledVault(), clipboard: ClipboardService(pasteboard: board), clock: { now })
        XCTAssertNil(store.secondsUntilLock(policy: .idle(minutes: 1)))
        await store.start()
        await store.unlock(masterPassword: "synthetic-master")
        now = 115.5
        XCTAssertEqual(store.secondsUntilLock(policy: .idle(minutes: 1)), 45)
        store.query = "cafe"
        XCTAssertEqual(store.secondsUntilLock(policy: .idle(minutes: 1)), 60)
        XCTAssertNil(store.secondsUntilLock(policy: .systemOnly))
        now = 1000
        XCTAssertEqual(store.secondsUntilLock(policy: .idle(minutes: 1)), 0)
        await store.lock().value
        XCTAssertNil(store.secondsUntilLock(policy: .idle(minutes: 1)))
    }
    func testCopiesAreUsableBeforeFoldersFinishButSyncWaits() async throws {
        let backend = ControlledVault()
        await backend.delayFolders()
        let (store, board) = make(backend)
        defer { board.releaseGlobally() }
        await store.start()
        let opening = Task { await store.unlock(masterPassword: "synthetic-master") }
        try await waitFor { await backend.foldersStarted }
        XCTAssertFalse(store.isWorking)
        XCTAssertTrue(store.isRefreshingFolders)
        store.copyUsername(for: "one")
        XCTAssertEqual(board.string(forType: .string), "alice")
        await store.copyPassword(for: "one")
        XCTAssertEqual(board.string(forType: .string), "synthetic-password")
        await store.copyTOTP(for: "one")
        XCTAssertEqual(board.string(forType: .string), "123456")
        await store.sync()
        let syncCalls = await backend.syncCalls
        XCTAssertEqual(syncCalls, 0)
        await backend.resumeFolders()
        await opening.value
        XCTAssertFalse(store.isRefreshingFolders)
        XCTAssertFalse(store.isWorking)
    }
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
