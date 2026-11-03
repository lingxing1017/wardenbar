import Foundation
import XCTest
@testable import WardenBarCore
@testable import WardenBarDesktop

final class TerminalLoginCommandTests: XCTestCase {
    func testCommandPreservesQuotedPathsAndDoesNotExecutePathContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("bw ' $(printf injected)")
        let script = "#!/usr/bin/python3\nimport json,os,sys\nprint(json.dumps([os.environ['BITWARDENCLI_APPDATA_DIR'],sys.argv[1:]]))\n"
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let data = root.appendingPathComponent("CLI ' with spaces")
        for method in TerminalLoginMethod.allCases {
            let command = TerminalLoginCommand.make(executable: binary, dataDirectory: data, server: .eu, method: method)
            let output = try await CLIProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], environment: ["PATH": "/usr/bin:/bin"])
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
            XCTAssertEqual(lines.count, 2)
            let config = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [Any]
            XCTAssertEqual(config[0] as? String, data.path)
            XCTAssertEqual(config[1] as? [String], ["config", "server", "https://vault.bitwarden.eu"])
            let login = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [Any]
            XCTAssertEqual(login[1] as? [String], ["login"] + method.arguments)
        }
    }
}
