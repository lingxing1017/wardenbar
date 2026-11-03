import XCTest
@testable import WardenBarDesktop

final class RuntimeOptionsTests: XCTestCase {
    func testExplicitPathsAndIsolatedDefault() throws {
        let options = try RuntimeOptions.parse(["--cli", "/trusted/bw", "--data-dir", "/dedicated/CLI"])
        XCTAssertEqual(options.cli?.path, "/trusted/bw")
        XCTAssertEqual(options.dataDirectory.path, "/dedicated/CLI")
        XCTAssertTrue(try RuntimeOptions.parse([]).dataDirectory.path.hasSuffix("Application Support/WardenBar/CLI"))
    }

    func testInvalidPathsDuplicateOptionsAndCredentialArgumentsAreRejected() {
        for values in [["--cli", "relative"], ["--password", "synthetic"], ["--data-dir"], ["--cli", "/a", "--cli", "/b"]] {
            XCTAssertThrowsError(try RuntimeOptions.parse(values))
        }
    }
}
