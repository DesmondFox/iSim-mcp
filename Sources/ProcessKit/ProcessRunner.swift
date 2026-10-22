import Foundation

/// Result of a finished child process.
public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessError: Error, CustomStringConvertible, Equatable {
    case launchFailed(command: String, reason: String)
    case timedOut(command: String, seconds: Double)

    public var description: String {
        switch self {
        case .launchFailed(let command, let reason):
            "Failed to start `\(command)`: \(reason)"
        case .timedOut(let command, let seconds):
            "`\(command)` did not finish in \(seconds.formatted()) s and was terminated."
        }
    }
}

/// Runs external commands. Backends depend on this protocol so tests can replace real processes.
public protocol ProcessRunning: Sendable {
    /// Runs `executable` and collects its output. A non-zero exit code is not an error here:
    /// callers decide what it means. Throws on launch failure, timeout and task cancellation.
    func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        timeout: Duration?
    ) async throws -> ProcessResult
}

extension ProcessRunning {
    public func run(_ executable: String, _ arguments: [String], timeout: Duration? = nil) async throws -> ProcessResult {
        try await run(executable, arguments, environment: [:], timeout: timeout)
    }
}

/// `Process`-based runner. stdout/stderr are read concurrently to avoid pipe deadlocks;
/// timeout and task cancellation send SIGTERM to the child's process group, then SIGKILL after a grace period.
public struct ProcessRunner: ProcessRunning {
    /// Variables added to every child's environment (e.g. `DEVELOPER_DIR`).
    public var baseEnvironment: [String: String]
    public var killGracePeriod: Duration
    /// How long to keep reading after the child exits. A grandchild that inherited the pipes
    /// (a daemon spawned by the tool) would otherwise keep the read open forever.
    public var drainTimeout: Duration

    public init(baseEnvironment: [String: String] = [:], killGracePeriod: Duration = .seconds(2), drainTimeout: Duration = .seconds(2)) {
        self.baseEnvironment = baseEnvironment
        self.killGracePeriod = killGracePeriod
        self.drainTimeout = drainTimeout
    }

    public func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        timeout: Duration?
    ) async throws -> ProcessResult {
        let commandLine = ([executable] + arguments).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(baseEnvironment) { $1 }
            .merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let child = ChildProcess(process, killGracePeriod: killGracePeriod)
        let stdout = OutputCollector(stdoutPipe.fileHandleForReading)
        let stderr = OutputCollector(stderrPipe.fileHandleForReading)
        do {
            try process.run()
        } catch {
            stdout.finish()
            stderr.finish()
            throw ProcessError.launchFailed(command: commandLine, reason: error.localizedDescription)
        }

        let exitCode = await withTaskCancellationHandler {
            await withTaskGroup(of: Int32?.self) { group in
                group.addTask { await child.waitForExit() }
                if let timeout {
                    group.addTask {
                        do { try await Task.sleep(for: timeout) } catch { return nil }
                        child.terminate(timedOut: true)
                        return nil
                    }
                }
                var status: Int32 = -1
                for await result in group {
                    if let result {
                        status = result
                        group.cancelAll()
                    }
                }
                return status
            }
        } onCancel: {
            child.terminate(timedOut: false)
        }

        async let stdoutData = stdout.collect(drainTimeout: drainTimeout)
        async let stderrData = stderr.collect(drainTimeout: drainTimeout)
        let result = ProcessResult(exitCode: exitCode, stdout: await stdoutData, stderr: await stderrData)
        if child.didTimeOut, let timeout {
            throw ProcessError.timedOut(command: commandLine, seconds: timeout.inSeconds)
        }
        try Task.checkCancellation()
        return result
    }
}

extension Duration {
    public var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Accumulates a pipe's output as it arrives, until EOF or until `collect` gives up waiting.
private final class OutputCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                finish()
            } else {
                lock.withLock { if !finished { data.append(chunk) } }
            }
        }
    }

    /// Waits for EOF, at most `drainTimeout`, and returns everything read so far.
    func collect(drainTimeout: Duration) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = lock.withLock {
                if !finished { waiters.append(continuation) }
                return finished
            }
            if done {
                continuation.resume()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + drainTimeout.inSeconds) { [self] in finish() }
            }
        }
        return lock.withLock { data }
    }

    func finish() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !finished else { return [] }
            finished = true
            defer { waiters = [] }
            return waiters
        }
        handle.readabilityHandler = nil
        pending.forEach { $0.resume() }
    }
}

/// Bridges `Process.terminationHandler` to async/await and owns termination.
private final class ChildProcess: @unchecked Sendable {
    private let process: Process
    private let killGracePeriod: Duration
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?
    private var timedOut = false

    init(_ process: Process, killGracePeriod: Duration) {
        self.process = process
        self.killGracePeriod = killGracePeriod
        process.terminationHandler = { [self] finished in
            self.finish(finished.terminationStatus)
        }
    }

    var didTimeOut: Bool { lock.withLock { timedOut } }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status: Int32? = lock.withLock {
                if let exitStatus { return exitStatus }
                waiter = continuation
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    /// Foundation starts the child as the leader of a new process group, so signalling `-pid`
    /// also reaches the processes it spawned.
    func terminate(timedOut: Bool) {
        let pid: pid_t? = lock.withLock {
            if timedOut { self.timedOut = true }
            return exitStatus == nil && process.isRunning ? process.processIdentifier : nil
        }
        guard let pid else { return }
        kill(-pid, SIGTERM)
        let grace = killGracePeriod
        Task.detached {
            try? await Task.sleep(for: grace)
            // The group outlives its leader while any member is alive.
            if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        }
    }

    private func finish(_ status: Int32) {
        let continuation: CheckedContinuation<Int32, Never>? = lock.withLock {
            exitStatus = status
            process.terminationHandler = nil
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(returning: status)
    }
}
