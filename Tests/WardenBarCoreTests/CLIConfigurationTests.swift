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
        let result = try CLIConfiguration.discover(searchPath: nil, candidates: [directory, plain, valid])
        XCTAssertEqual(result.executable, valid)
    }

    func testPathSearchPrecedesFallbackAndPreservesOrderAndSpaces() throws {
        let first = directory.appendingPathComponent("first bin")
        let second = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        for folder in [first, second] {
            let file = folder.appendingPathComponent("bw")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let fallback = try executable("fallback")
        let path = first.path + ":" + second.path
        let result = try CLIConfiguration.discover(searchPath: path, candidates: [fallback])
        XCTAssertEqual(result.executable, first.appendingPathComponent("bw"))
        let explicit = try CLIConfiguration.discover(executable: fallback, searchPath: path)
        XCTAssertEqual(explicit.executable, fallback)
        XCTAssertThrowsError(try CLIConfiguration.discover(executable: directory.appendingPathComponent("missing"), searchPath: path))
    }

    func testPathSearchSkipsInvalidEntriesAndFallsBack() throws {
        let invalid = directory.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: invalid.appendingPathComponent("bw"), withIntermediateDirectories: true)
        let plain = directory.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data().write(to: plain.appendingPathComponent("bw"))
        let fallback = try executable("fallback")
        for path: String? in [nil, "", ":.:relative:" + invalid.path + ":" + plain.path] {
            let config = try CLIConfiguration.discover(searchPath: path, candidates: [fallback])
            XCTAssertEqual(config.executable, fallback)
        }
        XCTAssertThrowsError(try CLIConfiguration.discover(searchPath: nil, candidates: []))
    }

    func testDiscoveredNodeScriptRunsWithItsPathInterpreter() async throws {
        let bin = directory.appendingPathComponent("custom cli")
        let runtime = directory.appendingPathComponent("custom runtime")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let bw = bin.appendingPathComponent("bw")
        let node = runtime.appendingPathComponent("node")
        try Data("#!/usr/bin/env node\n".utf8).write(to: bw)
        try Data("#!/bin/sh\nprintf '2026.10.1\\n'\n".utf8).write(to: node)
        for file in [bw, node] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let config = try CLIConfiguration.discover(dataDirectory: directory.appendingPathComponent("CLI"), searchPath: bin.path + ":" + runtime.path, candidates: [])
        let vault = BitwardenVault(configuration: config)
        let version = try await vault.version()
        XCTAssertEqual(version, "2026.10.1")
        let env = config.environment(parent: ["PATH": "/unrelated", "NODE_OPTIONS": "--require evil.js"])
        XCTAssertNil(env["NODE_OPTIONS"])
        XCTAssertFalse(env["PATH", default: ""].contains("unrelated"))
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
