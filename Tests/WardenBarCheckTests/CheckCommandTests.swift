import Foundation
import XCTest
@testable import WardenBarCheck

final class CheckCommandTests: XCTestCase {
    func testHelpDoesNotNeedInstalledCLI() async {
        let result = await CheckCommand.run(arguments: ["--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("--cli"))
        XCTAssertTrue(result.output.contains("--data-dir"))
    }

    func testUnknownAndMissingAndRelativeArgumentsFailWithoutEchoingValues() async {
        for arguments in [
            ["--password", "synthetic-secret"], ["--cli"], ["--cli", "relative/bw"],
            ["--cli", "/a", "--cli", "/b"], ["--data-dir", "--cli"]
        ] {
            let result = await CheckCommand.run(arguments: arguments)
            XCTAssertEqual(result.exitCode, 2)
            XCTAssertFalse(result.output.contains("synthetic-secret"))
        }
    }

    func testMissingExplicitCLIDoesNotFallBackOrExposePath() async {
        let result = await CheckCommand.run(arguments: ["--cli", "/missing/synthetic-secret"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.output.contains("synthetic-secret"))
        XCTAssertTrue(result.output.contains("CLI"))
    }

    func testFixtureReportContainsOnlyVersionAndCoarseStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WardenBarCoreTests/Fixtures/bw-fixture")
        let binary = root.appendingPathComponent("bw")
        try FileManager.default.copyItem(at: source, to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let result = await CheckCommand.run(arguments: [
            "--cli", binary.path, "--data-dir", root.appendingPathComponent("CLI").path
        ])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "CLI version: 2026.10.0\nVault status: locked\n")
        XCTAssertFalse(result.output.contains("example.invalid"))
        XCTAssertFalse(result.output.contains("synthetic"))
    }
}
