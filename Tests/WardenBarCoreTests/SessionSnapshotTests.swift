import Foundation
import XCTest
@testable import WardenBarCore

final class SessionSnapshotTests: XCTestCase {
    private var directory: URL!
    private var configuration: CLIConfiguration!
    private var vault: BitwardenVault!
    private let id = "11111111-1111-1111-1111-111111111111"

    override func setUpWithError() throws {
        directory = try temporaryDirectory()
        configuration = try fixtureConfiguration(directory: directory)
        try configuration.prepareDataDirectory()
        try flag("snapshot-data")
        vault = BitwardenVault(configuration: configuration, readPolicy: .sessionSnapshot, clock: { Date(timeIntervalSince1970: 59) })
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func flag(_ name: String) throws { try Data().write(to: configuration.dataDirectory.appendingPathComponent(name)) }
    private func prime() async throws {
        try await vault.unlock(masterPassword: "synthetic-master")
        _ = try await vault.items()
    }
    private func assertUnavailable() async {
        do { _ = try await vault.password(for: id); XCTFail("Stale password") } catch {}
        do { _ = try await vault.totp(for: id); XCTFail("Stale code") } catch {}
    }

    func testRepeatedCopiesUseNoGetSubprocesses() async throws {
        try await prime()
        try flag("reject-get")
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            let password = try await vault.password(for: id)
            let code = try await vault.totp(for: id)
            XCTAssertEqual(password.withValue { $0 }, "\n secret\t \n")
            XCTAssertEqual(code.withValue { $0 }, "287082")
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        let commands = try String(contentsOf: configuration.dataDirectory.appendingPathComponent("commands"))
        XCTAssertFalse(commands.split(separator: "\n").contains(where: { $0.hasPrefix("get ") }))
        print("Synthetic snapshot benchmark: 100 password/code pairs, \(Int(elapsed)) ms, zero get subprocesses")
    }

    func testCopiesRemainAvailableWhileFolderMetadataLoads() async throws {
        try await prime()
        try flag("delay-folders")
        let loading = Task { try await vault.folders() }
        try await waitForFile(configuration.dataDirectory.appendingPathComponent("folders-started"))
        _ = try await vault.password(for: id)
        _ = try await vault.totp(for: id)
        try flag("release-folders")
        _ = try await loading.value
    }

    func testRefreshReplacesSnapshotAndExcludesReprotectedItems() async throws {
        try await prime()
        try flag("changed-password")
        // Session snapshots deliberately reflect the last indexed version until refresh.
        let old = try await vault.password(for: id)
        XCTAssertEqual(old.withValue { $0 }, "\n secret\t \n")
        _ = try await vault.items()
        let updated = try await vault.password(for: id)
        XCTAssertEqual(updated.withValue { $0 }, "new-synthetic-password")
        try flag("protected-list")
        let items = try await vault.items()
        XCTAssertTrue(items.isEmpty)
        await assertUnavailable()
    }

    func testFailedListAndSyncRevokePreviousSnapshot() async throws {
        try await prime()
        try flag("malformed-list")
        do { _ = try await vault.items(); XCTFail("Malformed list") } catch {}
        await assertUnavailable()
        try FileManager.default.removeItem(at: configuration.dataDirectory.appendingPathComponent("malformed-list"))
        _ = try await vault.items()
        try flag("fail-sync")
        do { try await vault.sync(); XCTFail("Sync failure") } catch {}
        await assertUnavailable()
    }

    func testSyncRevokesSnapshotUntilItIsRebuilt() async throws {
        try await prime()
        try await vault.sync()
        await assertUnavailable()
        _ = try await vault.items()
        _ = try await vault.password(for: id)
    }

    func testFailedLockStillRevokesSnapshot() async throws {
        try await prime()
        try flag("fail-lock")
        do { try await vault.lock(); XCTFail("Lock failure") } catch {}
        await assertUnavailable()
    }

    func testLockedStatusRevokesSnapshot() async throws {
        try await prime()
        try flag("forced-locked-status")
        let status = try await vault.status()
        XCTAssertEqual(status, .locked)
        await assertUnavailable()
    }

    func testLockDuringListCannotRepopulateSnapshot() async throws {
        try await prime()
        try flag("delay-list")
        try FileManager.default.removeItem(at: configuration.dataDirectory.appendingPathComponent("list-started"))
        let loading = Task { try await vault.items() }
        try await waitForFile(configuration.dataDirectory.appendingPathComponent("list-started"))
        try await vault.lock()
        do { _ = try await loading.value; XCTFail("Stale list") } catch {}
        await assertUnavailable()
    }
}
