import Foundation
import XCTest
@testable import WardenBarCore

final class CLIConfigurationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func executable(_ name: String = "bw") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testExplicitMissingPathDoesNotSilentlyFallBack() throws {
        let valid = try executable()
        XCTAssertThrowsError(try CLIConfiguration.discover(
            executable: directory.appendingPathComponent("missing"), candidates: [valid]
        ))
    }

    func testDiscoverySkipsNonExecutableAndDirectories() throws {
        let plain = directory.appendingPathComponent("plain")
        try Data().write(to: plain)
        let valid = try executable()
        let result = try CLIConfiguration.discover(candidates: [directory, plain, valid])
        XCTAssertEqual(result.executable, valid)
    }

    func testPrivateDirectoryIsCreatedAndExistingPermissionsAreRestricted() throws {
        let data = directory.appendingPathComponent("isolated/CLI")
        let config = try CLIConfiguration.discover(executable: executable(), dataDirectory: data)
        try config.prepareDataDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
        try config.prepareDataDirectory()
        let attributes = try FileManager.default.attributesOfItem(atPath: data.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testSymlinkDataDirectoryIsRejected() throws {
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let config = try CLIConfiguration.discover(executable: executable(), dataDirectory: link)
        XCTAssertThrowsError(try config.prepareDataDirectory())
    }

    func testDefaultDirectoryIsSeparateFromDefaultBitwardenDirectory() throws {
        let config = try CLIConfiguration.discover(executable: executable())
        XCTAssertTrue(config.dataDirectory.path.hasSuffix("Application Support/WardenBar/CLI"))
    }

    func testEnvironmentDropsInheritedSecretsAndNodeInjection() throws {
        let config = try CLIConfiguration.discover(executable: executable(), dataDirectory: directory)
        let env = config.environment(parent: [
            "HOME": "/test/home", "BW_SESSION": "inherited-secret",
            "BW_UNLOCK_PASSWORD": "inherited-password", "NODE_OPTIONS": "--require evil.js",
            "BITWARDENCLI_DEBUG": "true", "PATH": "/untrusted"
        ])
        XCTAssertEqual(env["HOME"], "/test/home")
        XCTAssertEqual(env["BITWARDENCLI_APPDATA_DIR"], directory.path)
        XCTAssertNil(env["BW_SESSION"])
        XCTAssertNil(env["BW_UNLOCK_PASSWORD"])
        XCTAssertNil(env["NODE_OPTIONS"])
        XCTAssertNil(env["BITWARDENCLI_DEBUG"])
        XCTAssertFalse(env["PATH", default: ""].contains("untrusted"))
    }
}
