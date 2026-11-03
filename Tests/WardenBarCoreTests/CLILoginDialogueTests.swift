import Foundation
import XCTest
@testable import WardenBarCore

private final class Challenges: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CLILoginChallenge] = []
    func append(_ value: CLILoginChallenge) { lock.withLock { values.append(value) } }
    var count: Int { lock.withLock { values.count } }
}

final class CLILoginDialogueTests: XCTestCase {
    func testPartialPromptsAreRecognizedOnceAndInputsAreRedacted() throws {
        let events = Challenges()
        let dialogue = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { events.append($0) })
        try dialogue.receiveStderr(Data("\u{1b}[32m? Email add".utf8))
        XCTAssertNil(dialogue.nextInput())
        try dialogue.receiveStderr(Data("ress:\u{1b}[0m ".utf8))
        XCTAssertEqual(dialogue.nextInput(), Data("synthetic@example.invalid\n".utf8))
        try dialogue.receiveStderr(Data("Email address: synthetic@example.invalid\nTwo-step login code:".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(dialogue.submit("123456"))
        XCTAssertFalse(dialogue.submit("654321"))
        XCTAssertEqual(dialogue.nextInput(), Data("123456\n".utf8))
        XCTAssertFalse(String(reflecting: dialogue).contains("synthetic"))
        try dialogue.receiveStderr(Data("Two-step login code: 123456".utf8))
        XCTAssertEqual(events.count, 1)
    }

    func testUnsupportedPromptsAndLineInjectionAreRejected() throws {
        XCTAssertThrowsError(try CLILoginDialogue(email: "a@example.invalid\nsecond", onChallenge: { _ in }))
        let dialogue = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { _ in })
        try dialogue.receiveStderr(Data("Two-step login code:".utf8))
        XCTAssertFalse(dialogue.submit("first\nsecond"))
        XCTAssertFalse(dialogue.submit(""))
        XCTAssertTrue(dialogue.submit("123456"))
        XCTAssertThrowsError(try dialogue.receiveStderr(Data("Two-step login method:".utf8)))
    }

    func testRunnerKeepsInteractivePipeOpenUntilNextPrompt() async throws {
        let dialogue = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { _ in })
        let script = "import sys\nsys.stderr.write('Email address:');sys.stderr.flush()\nemail=input()\nsys.stderr.write('New device verification required. Enter OTP sent to login email:');sys.stderr.flush()\ncode=input()\nassert email=='synthetic@example.invalid' and code=='123456'\nprint('done',end='')"
        let task = Task { try await CLIProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], environment: [:], interaction: dialogue, timeout: 3) }
        let deadline = Date().addingTimeInterval(2)
        while !dialogue.submit("123456"), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let output = try await task.value
        XCTAssertEqual(output, Data("done".utf8))
    }

    func testWaitingForChallengeCanBeCancelled() async throws {
        let events = Challenges()
        let dialogue = try CLILoginDialogue(email: "synthetic@example.invalid", onChallenge: { events.append($0) })
        let task = Task { try await CLIProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import sys;sys.stderr.write('Two-step login code:');sys.stderr.flush();input()"], environment: [:], interaction: dialogue, timeout: 3) }
        let deadline = Date().addingTimeInterval(2)
        while events.count == 0, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(events.count, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
