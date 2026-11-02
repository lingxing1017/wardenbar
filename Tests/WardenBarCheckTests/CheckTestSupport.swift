import Foundation
import XCTest
import WardenBarCore

final class CheckFixture {
    let root: URL
    let configuration: CLIConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("WardenBarCoreTests/Fixtures/bw-fixture")
        let binary = root.appendingPathComponent("bw")
        try FileManager.default.copyItem(at: source, to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        configuration = try CLIConfiguration.discover(executable: binary, dataDirectory: root.appendingPathComponent("CLI"))
        try configuration.prepareDataDirectory()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func flag(_ name: String) throws {
        try Data().write(to: configuration.dataDirectory.appendingPathComponent(name))
    }

    func hasFile(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: configuration.dataDirectory.appendingPathComponent(name).path)
    }

    func waitForFile(_ name: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !hasFile(name) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NSError(domain: "FixtureDidNotStart", code: 1)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
