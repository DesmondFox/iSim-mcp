import Foundation
import ProcessKit

/// `ProcessRunning` double: answers commands from a script and records every call.
public final class ScriptedRunner: ProcessRunning, @unchecked Sendable {
    public struct Call: Sendable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]

        public var commandLine: String { arguments.joined(separator: " ") }
    }

    private let lock = NSLock()
    private var rules: [(pattern: String, result: ProcessResult)] = []
    private var recorded: [Call] = []

    public init() {}

    /// Answers the first command whose arguments, joined by spaces, contain `pattern`.
    public func on(_ pattern: String, exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        on(pattern, result: ProcessResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)))
    }

    public func on(_ pattern: String, result: ProcessResult) {
        lock.withLock { rules.append((pattern, result)) }
    }

    public var calls: [Call] { lock.withLock { recorded } }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: Duration?) async throws -> ProcessResult {
        let call = Call(executable: executable, arguments: arguments, environment: environment)
        return lock.withLock {
            recorded.append(call)
            let line = call.commandLine
            return rules.first { line.contains($0.pattern) }?.result
                ?? ProcessResult(exitCode: 127, stderr: Data("ScriptedRunner: no rule for `\(line)`".utf8))
        }
    }
}
