import Foundation
import XCTest
@testable import WardenBarCheck

final class VaultSmokeCheckTests: XCTestCase {
    func testSuccessfulReadOnlyWorkflowLocksAndNeverReportsVaultContents() async throws {
        let fixture = try CheckFixture()
        let result = await VaultSmokeCheck.run(configuration: fixture.configuration) { "synthetic-master" }
        XCTAssertEqual(result.exitCode, 0)
        for step in ["Unlock: passed", "Sync: passed", "Item listing: passed", "Password read: passed", "Lock: passed"] {
            XCTAssertTrue(result.output.contains(step), step)
        }
        for sensitive in ["synthetic", "secret", "example.invalid", "11111111"] {
            XCTAssertFalse(result.output.contains(sensitive))
        }
        XCTAssertTrue(fixture.hasFile("lock-called"))
    }

    func testSyncFailureStillLocksAndDoesNotPrintRawError() async throws {
        let fixture = try CheckFixture()
        try fixture.flag("fail-sync")
        let result = await VaultSmokeCheck.run(configuration: fixture.configuration) { "synthetic-master" }
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("Sync: FAILED"))
        XCTAssertTrue(result.output.contains("Lock: passed"))
        XCTAssertFalse(result.output.contains("synthetic-sensitive"))
        XCTAssertTrue(fixture.hasFile("lock-called"))
    }

    func testLockFailurePreventsSuccessEvenAfterPasswordRead() async throws {
        let fixture = try CheckFixture()
        try fixture.flag("fail-lock")
        let result = await VaultSmokeCheck.run(configuration: fixture.configuration) { "synthetic-master" }
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("Password read: passed"))
        XCTAssertTrue(result.output.contains("Lock: FAILED"))
        XCTAssertFalse(result.output.contains("Check: passed"))
    }

    func testEmptyVaultReportsIncompleteReadAndStillLocks() async throws {
        let fixture = try CheckFixture()
        try fixture.flag("empty-list")
        let result = await VaultSmokeCheck.run(configuration: fixture.configuration) { "synthetic-master" }
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.output.contains("Password read: skipped"))
        XCTAssertTrue(result.output.contains("Lock: passed"))
    }

    func testUnauthenticatedDirectoryDoesNotAskForPasswordOrAttemptLock() async throws {
        let fixture = try CheckFixture()
        try fixture.flag("unauthenticated-status")
        let result = await VaultSmokeCheck.run(configuration: fixture.configuration) {
            XCTFail("Do not prompt before login")
            return "synthetic-master"
        }
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(fixture.hasFile("unlock-started"))
        XCTAssertFalse(fixture.hasFile("lock-called"))
    }

    func testCancellationDuringSyncStillAttemptsBackendLock() async throws {
        let fixture = try CheckFixture()
        try fixture.flag("delay-sync")
        let check = Task {
            await VaultSmokeCheck.run(configuration: fixture.configuration) { "synthetic-master" }
        }
        try await fixture.waitForFile("sync-started")
        check.cancel()
        let result = await check.value
        XCTAssertEqual(result.exitCode, 130)
        XCTAssertTrue(result.output.contains("Lock: passed"))
        XCTAssertTrue(fixture.hasFile("lock-called"))
    }
}
