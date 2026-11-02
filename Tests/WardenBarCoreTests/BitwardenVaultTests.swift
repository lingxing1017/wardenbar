import Foundation
import XCTest
@testable import WardenBarCore

final class BitwardenVaultTests: XCTestCase {
    private var directory: URL!
    private var configuration: CLIConfiguration!
    private var vault: BitwardenVault!
    private let itemID = "11111111-1111-1111-1111-111111111111"

    override func setUpWithError() throws {
        directory = try temporaryDirectory()
        configuration = try fixtureConfiguration(directory: directory)
        try configuration.prepareDataDirectory()
        vault = BitwardenVault(configuration: configuration)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func flag(_ name: String) throws {
        try Data().write(to: configuration.dataDirectory.appendingPathComponent(name))
    }

    func testUnlockIndexReadSyncAndLockThroughRealSubprocesses() async throws {
        try await vault.unlock(masterPassword: "synthetic-master")
        let status = try await vault.status()
        XCTAssertEqual(status, .unlocked)
        let items = try await vault.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, itemID)
        XCTAssertEqual(items.first?.username, "synthetic-user")
        XCTAssertFalse(String(reflecting: items).contains("synthetic-seed"))
        let password = try await vault.password(for: itemID)
        XCTAssertEqual(password.withValue { $0 }, "\n secret\t \n")
        XCTAssertFalse(String(reflecting: password).contains("secret"))
        try await vault.sync()
        try await vault.lock()
        let state = await vault.state
        XCTAssertEqual(state, .locked)
        do {
            _ = try await vault.password(for: itemID)
            XCTFail("Locked vault must reject password access")
        } catch let error as VaultError { XCTAssertEqual(error, .locked) }
    }

    func testReadsRequireUnlockAndIndexMembership() async throws {
        do {
            _ = try await vault.items()
            XCTFail("Expected locked access rejection")
        } catch let error as VaultError { XCTAssertEqual(error, .locked) }
        try await vault.unlock(masterPassword: "synthetic-master")
        do {
            _ = try await vault.password(for: itemID)
            XCTFail("No direct access before indexing")
        } catch let error as VaultError { XCTAssertEqual(error, .itemUnavailable) }
    }

    func testProtectionIsRecheckedWhenReadingAnIndexedItem() async throws {
        try await vault.unlock(masterPassword: "synthetic-master")
        _ = try await vault.items()
        try flag("protected-read")
        do {
            _ = try await vault.password(for: itemID)
            XCTFail("Reprompt items are unsupported and must remain protected")
        } catch let error as VaultError { XCTAssertEqual(error, .itemUnavailable) }
    }

    func testMalformedListClearsPreviouslyAuthorizedItemIDs() async throws {
        try await vault.unlock(masterPassword: "synthetic-master")
        _ = try await vault.items()
        try flag("malformed-list")
        do {
            _ = try await vault.items()
            XCTFail("Expected invalid response")
        } catch let error as VaultError {
            XCTAssertEqual(error, .invalidResponse)
            XCTAssertFalse(String(reflecting: error).contains("sensitive"))
        }
        do {
            _ = try await vault.password(for: itemID)
            XCTFail("Malformed refresh must invalidate old index authorization")
        } catch let error as VaultError { XCTAssertEqual(error, .itemUnavailable) }
    }

    func testLockFailureStillDropsLocalAccess() async throws {
        try await vault.unlock(masterPassword: "synthetic-master")
        try flag("fail-lock")
        do {
            try await vault.lock()
            XCTFail("Expected backend lock failure")
        } catch let error as CLIProcessError { XCTAssertEqual(error, .nonzeroExit(9)) }
        let state = await vault.state
        XCTAssertEqual(state, .lockFailed)
        do {
            _ = try await vault.items()
            XCTFail("Failed backend lock cannot preserve local access")
        } catch let error as VaultError { XCTAssertEqual(error, .locked) }
    }

    func testLockDuringUnlockCannotResurrectSession() async throws {
        try flag("delay-unlock")
        let opening = Task { try await vault.unlock(masterPassword: "synthetic-master") }
        try await waitForFile(configuration.dataDirectory.appendingPathComponent("unlock-started"))
        try await vault.lock()
        do {
            try await opening.value
            XCTFail("Old unlock must not succeed after lock")
        } catch let error as VaultError { XCTAssertEqual(error, .sessionChanged) }
        let state = await vault.state
        XCTAssertEqual(state, .locked)
    }

    func testStatusPollingPreservesLockFailureUntilSuccessfulRetry() async throws {
        try await vault.unlock(masterPassword: "synthetic-master")
        try flag("fail-lock")
        do {
            try await vault.lock()
            XCTFail("Expected backend lock failure")
        } catch let error as CLIProcessError { XCTAssertEqual(error, .nonzeroExit(9)) }

        let backendStatus = try await vault.status()
        XCTAssertEqual(backendStatus, .locked)
        let failedState = await vault.state
        XCTAssertEqual(failedState, .lockFailed)

        try FileManager.default.removeItem(at: configuration.dataDirectory.appendingPathComponent("fail-lock"))
        try await vault.lock()
        let recoveredState = await vault.state
        XCTAssertEqual(recoveredState, .locked)
    }

    func testLockDuringReadDiscardsOldPasswordResult() async throws {
        try await vault.unlock(masterPassword: "synthetic-master")
        _ = try await vault.items()
        try flag("delay-read")
        let reading = Task { try await vault.password(for: itemID) }
        try await waitForFile(configuration.dataDirectory.appendingPathComponent("read-started"))
        try await vault.lock()
        do {
            _ = try await reading.value
            XCTFail("Old password request must not succeed")
        } catch let error as VaultError { XCTAssertEqual(error, .sessionChanged) }
    }

    func testConcurrentUnlockIsRejectedWithoutReplacingFirstSession() async throws {
        try flag("delay-unlock")
        let opening = Task { try await vault.unlock(masterPassword: "synthetic-master") }
        try await waitForFile(configuration.dataDirectory.appendingPathComponent("unlock-started"))
        do {
            try await vault.unlock(masterPassword: "synthetic-master")
            XCTFail("Expected busy")
        } catch let error as VaultError { XCTAssertEqual(error, .busy) }
        try flag("release-unlock")
        try await opening.value
        let state = await vault.state
        XCTAssertEqual(state, .unlocked)
    }

    func testConcurrentDataOperationsAreRejectedRatherThanSharingCLIStorage() async throws {
        try await vault.unlock(masterPassword: "synthetic-master")
        try flag("delay-list")
        let listing = Task { try await vault.items() }
        try await waitForFile(configuration.dataDirectory.appendingPathComponent("list-started"))
        do {
            try await vault.sync()
            XCTFail("Expected busy")
        } catch let error as VaultError { XCTAssertEqual(error, .busy) }
        try flag("release-list")
        _ = try await listing.value
    }

    func testFailedUnlockDoesNotKeepAUsableSession() async throws {
        try flag("bad-session")
        do {
            try await vault.unlock(masterPassword: "synthetic-master")
            XCTFail("Expected invalid session output")
        } catch let error as VaultError { XCTAssertEqual(error, .invalidResponse) }
        let state = await vault.state
        XCTAssertEqual(state, .locked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.dataDirectory.appendingPathComponent("lock-called").path))
    }

    func testSyncFailureDoesNotLogOutLocalSession() async throws {
        try await vault.unlock(masterPassword: "synthetic-master")
        try flag("fail-sync")
        do {
            try await vault.sync()
            XCTFail("Expected sync failure")
        } catch let error as CLIProcessError { XCTAssertEqual(error, .nonzeroExit(8)) }
        let state = await vault.state
        XCTAssertEqual(state, .unlocked)
    }
}
