import Foundation
import XCTest
@testable import WardenBarCore

func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func waitForFile(_ url: URL, timeout: TimeInterval = 3) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !FileManager.default.fileExists(atPath: url.path) {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw NSError(domain: "FixtureDidNotStart", code: 1)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

func fixtureConfiguration(directory: URL) throws -> CLIConfiguration {
    let fixture = try XCTUnwrap(Bundle.module.url(forResource: "bw-fixture", withExtension: nil, subdirectory: "Fixtures"))
    let binary = directory.appendingPathComponent("bw-fixture")
    try FileManager.default.copyItem(at: fixture, to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    return try CLIConfiguration.discover(executable: binary, dataDirectory: directory.appendingPathComponent("CLI"))
}
