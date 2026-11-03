import Foundation
import XCTest
@testable import WardenBarCore

final class AccountConnectionTests: XCTestCase {
    private func make() throws -> (BitwardenVault, URL) {
        let root = try temporaryDirectory()
        let source = try XCTUnwrap(Bundle.module.url(forResource: "bw-login-fixture", withExtension: nil, subdirectory: "Fixtures"))
        let binary = root.appendingPathComponent("bw")
        try FileManager.default.copyItem(at: source, to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let config = try CLIConfiguration.discover(executable: binary, dataDirectory: root)
        return (BitwardenVault(configuration: config, readPolicy: .sessionSnapshot), root)
    }
    func testServerValidationPreservesSubpathsAndRejectsUnsafeURLs() throws {
        XCTAssertEqual(try VaultServer(address: "https://example.invalid/vault/").url.absoluteString, "https://example.invalid/vault")
        XCTAssertNoThrow(try VaultServer(address: "http://127.0.0.1:8080"))
        for value in ["http://example.invalid", "https://user:password@example.invalid", "https://example.invalid?a=b", "https://example.invalid/#x", "file:///tmp/a", "https://example.invalid/\npath"] {
            XCTAssertThrowsError(try VaultServer(address: value), value)
        }
    }
    func testNativeLoginHandlesEachKnownChallengeAndRemainsLoggedInAfterLock() async throws {
        let (vault, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        for flag in ["needs-code", "needs-device", "needs-secret"] { FileManager.default.createFile(atPath: root.appendingPathComponent(flag).path, contents: Data()) }
        _ = try await vault.status()
        var dialogue: CLILoginDialogue!
        let box = DialogueBox()
        dialogue = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { _ in box.submit() })
        box.dialogue = dialogue
        try await vault.login(server: .us, masterPassword: "synthetic-master", method: .authenticator, dialogue: dialogue)
        let state = await vault.state
        XCTAssertEqual(state, .unlocked)
        let items = try await vault.items()
        XCTAssertTrue(items.isEmpty)
        try await vault.lock()
        let status = try await vault.status()
        XCTAssertEqual(status, .locked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("configured").path))
        do { try await vault.login(server: .eu, masterPassword: "synthetic-master", method: .authenticator, dialogue: dialogue); XCTFail("Must not replace authenticated profile") }
        catch { }
    }
    func testInvalidLoginSessionTriggersBackendLock() async throws {
        let (vault, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("bad-session").path, contents: Data())
        _ = try await vault.status()
        let dialogue = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { _ in })
        do { try await vault.login(server: .us, masterPassword: "synthetic-master", method: .authenticator, dialogue: dialogue); XCTFail("Expected invalid Session") }
        catch { XCTAssertFalse(String(reflecting: error).contains("sensitive")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-called").path))
    }
    func testFailedLoginRemainsRetryableWithoutAuthenticatedLock() async throws {
        let (vault, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("fail-login").path, contents: Data())
        _ = try await vault.status()
        let first = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { _ in })
        do { try await vault.login(server: .us, masterPassword: "synthetic-master", method: .authenticator, dialogue: first); XCTFail("Expected login failure") } catch { }
        let state = await vault.state
        XCTAssertEqual(state, .unauthenticated)
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-login"))
        let retry = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { _ in })
        try await vault.login(server: .us, masterPassword: "synthetic-master", method: .authenticator, dialogue: retry)
        let completed = await vault.state
        XCTAssertEqual(completed, .unlocked)
        try await vault.lock()
    }

    func testUnknownLoginCleanupStateKeepsLockFailureBlocked() async throws {
        let (vault, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("needs-code").path, contents: Data())
        _ = try await vault.status()
        let dialogue = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { _ in })
        let signingIn = Task { try await vault.login(server: .us, masterPassword: "synthetic-master", method: .authenticator, dialogue: dialogue) }
        try await waitForFile(root.appendingPathComponent("needs-code-started"))
        FileManager.default.createFile(atPath: root.appendingPathComponent("fail-status").path, contents: Data())
        do { try await vault.lock(); XCTFail("Unknown state must remain blocked") } catch { }
        _ = await signingIn.result
        let state = await vault.state
        XCTAssertEqual(state, .lockFailed)
    }

    func testPartialAuthenticationLockFailureSurvivesCoarseStatus() async throws {
        let (vault, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        for flag in ["bad-session", "fail-lock"] { FileManager.default.createFile(atPath: root.appendingPathComponent(flag).path, contents: Data()) }
        _ = try await vault.status()
        let dialogue = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { _ in })
        do { try await vault.login(server: .us, masterPassword: "synthetic-master", method: .authenticator, dialogue: dialogue); XCTFail("Expected failure") } catch { }
        _ = try await vault.status()
        let state = await vault.state
        XCTAssertEqual(state, .lockFailed)
    }

    func testLockPreemptsLoginWaitingForCode() async throws {
        let (vault, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("needs-code").path, contents: Data())
        _ = try await vault.status()
        let dialogue = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { _ in })
        let task = Task { try await vault.login(server: .us, masterPassword: "synthetic-master", method: .authenticator, dialogue: dialogue) }
        try await waitForFile(root.appendingPathComponent("needs-code-started"))
        try await vault.lock()
        do { try await task.value; XCTFail("Late login must fail") } catch { }
        let state = await vault.state
        XCTAssertEqual(state, .unauthenticated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-called").path))
    }
}

private final class DialogueBox: @unchecked Sendable {
    var dialogue: CLILoginDialogue?
    func submit() { dialogue?.submit("123456") }
}
