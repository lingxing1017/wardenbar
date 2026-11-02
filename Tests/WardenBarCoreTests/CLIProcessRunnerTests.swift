import Foundation
import XCTest
@testable import WardenBarCore

final class CLIProcessRunnerTests: XCTestCase {
    private let runner = CLIProcessRunner()

    func testArgumentsStayLiteralAndStdinRoundTripsWithoutFiles() async throws {
        let input = Data("\n  synthetic password \t\n".utf8)
        let output = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$1\"; /bin/cat", "fixture", "$(not-a-command); *"],
            environment: [:], input: input
        )
        XCTAssertEqual(output, Data("$(not-a-command); *".utf8) + input)
    }

    func testDrainsBothPipesBeyondKernelBufferCapacity() async throws {
        let output = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: ["BEGIN { for(i=0;i<200000;i++){printf \"a\"; printf \"b\" > \"/dev/stderr\"} }"],
            environment: [:], timeout: 5
        )
        XCTAssertEqual(output, Data(repeating: 97, count: 200000))
    }

    func testNonzeroExitDoesNotExposeEitherOutputStream() async throws {
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf synthetic-secret; printf synthetic-secret >&2; exit 7"],
                environment: [:]
            )
            XCTFail("Expected a nonzero exit")
        } catch let error as CLIProcessError {
            XCTAssertEqual(error, .nonzeroExit(7))
            XCTAssertFalse(String(reflecting: error).contains("synthetic-secret"))
        }
    }

    func testOutputLimitAppliesToStderrToo() async throws {
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/awk"),
                arguments: ["BEGIN { for(i=0;i<100000;i++) printf \"b\" > \"/dev/stderr\" }"],
                environment: [:], outputLimit: 1024
            )
            XCTFail("Expected bounded output")
        } catch let error as CLIProcessError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
    }

    func testTimeoutKillsChildThatIgnoresTermination() async throws {
        let start = Date()
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                environment: [:], timeout: 0.1
            )
            XCTFail("Expected timeout")
        } catch let error as CLIProcessError {
            XCTAssertEqual(error, .timedOut)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testCancellationStopsRunningChild() async throws {
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                environment: [:], timeout: 10
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let start = Date()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testAlreadyCancelledTaskDoesNotLaunch() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(
                executable: URL(fileURLWithPath: "/not-an-executable"),
                arguments: [], environment: [:]
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLaunchFailureIsCategorizedWithoutPathOrSystemOutput() async throws {
        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/missing/synthetic-secret"),
                arguments: [], environment: [:]
            )
            XCTFail("Expected launch failure")
        } catch let error as CLIProcessError {
            XCTAssertEqual(error, .launchFailed)
            XCTAssertFalse(String(reflecting: error).contains("synthetic-secret"))
        }
    }
}
