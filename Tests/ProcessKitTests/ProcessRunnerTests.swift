import Foundation
import ProcessKit
import Testing

struct ProcessRunnerTests {
    let runner = ProcessRunner(killGracePeriod: .milliseconds(500))

    @Test func capturesStdoutAndExitCode() async throws {
        let result = try await runner.run("/bin/echo", ["hello", "world"])
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "hello world\n")
    }

    @Test func returnsNonZeroExitAndStderr() async throws {
        let result = try await runner.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.stderrString == "oops\n")
        #expect(!result.succeeded)
    }

    @Test func readsLargeOutputOnBothStreamsWithoutDeadlock() async throws {
        let script = "head -c 2000000 /dev/zero; head -c 2000000 /dev/zero >&2"
        let result = try await runner.run("/bin/sh", ["-c", script], timeout: .seconds(20))
        #expect(result.stdout.count == 2_000_000)
        #expect(result.stderr.count == 2_000_000)
    }

    @Test func passesEnvironment() async throws {
        let runner = ProcessRunner(baseEnvironment: ["BASE_VAR": "base"])
        let result = try await runner.run("/usr/bin/env", [], environment: ["CALL_VAR": "call"], timeout: nil)
        #expect(result.stdoutString.contains("BASE_VAR=base"))
        #expect(result.stdoutString.contains("CALL_VAR=call"))
    }

    @Test func timeoutTerminatesTheProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ProcessError.timedOut(command: "/bin/sleep 30", seconds: 0.3)) {
            try await runner.run("/bin/sleep", ["30"], timeout: .milliseconds(300))
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func timeoutKillsProcessesThatIgnoreSIGTERM() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ProcessError.self) {
            try await runner.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: .milliseconds(300))
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func exitIsNotHeldUpByAGrandchildKeepingThePipeOpen() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let runner = ProcessRunner(drainTimeout: .milliseconds(300))
        let result = try await runner.run("/bin/sh", ["-c", "echo started; sleep 30 &"], timeout: .seconds(10))
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "started\n")
        #expect(clock.now - start < .seconds(5))
    }

    @Test func cancellationTerminatesTheProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await runner.run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func missingExecutableIsALaunchFailure() async throws {
        await #expect(throws: ProcessError.self) {
            try await runner.run("/nonexistent/tool", [])
        }
    }
}
