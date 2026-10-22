import DeviceCore
import Foundation
import SimBridge
import XPC

/// The session-long connection to one simulator's `dtuhidd`. A new connection costs ~0.8 s (lookup, barrier,
/// peer activation), so it is kept and only re-checked when XPC reports the daemon gone.
actor HIDChannel {
    /// `dtuhidd` starts on demand and can crash during a slow boot, after which launchd holds its restart for ~10 s.
    static let probeTimeout: TimeInterval = 4
    static let probeAttempts = 3
    static let retryDelay = Duration.seconds(4)
    /// The daemon drops events that arrive right after it activates a peer.
    static let activationTail = Duration.milliseconds(200)

    private let simulator: SBSimulator
    private var connection: SBXPCConnection?
    /// `interruptions` of the connection when a barrier last came back.
    private var confirmedInterruptions: UInt = 0

    init(simulator: SBSimulator) {
        self.simulator = simulator
    }

    /// Runs the steps in order. A cancelled task still sends every message, without the pauses,
    /// so no finger or key is left down.
    func run(_ steps: [HIDStep]) async throws {
        let connection = try await readyConnection()
        for step in steps {
            switch step {
            case .send(let message):
                connection.sendMessage(message.xpcObject())
            case .wait(let duration):
                try? await Task.sleep(for: duration)
            }
        }
        await withCheckedContinuation { continuation in
            connection.flush { continuation.resume() }
        }
    }

    private func readyConnection() async throws -> SBXPCConnection {
        if let connection, !connection.isInvalidated, connection.interruptions == confirmedInterruptions {
            return connection
        }
        var lastProblem = "no answer"
        var waitBeforeRetry = false
        for _ in 1...Self.probeAttempts {
            if waitBeforeRetry { try await Task.sleep(for: Self.retryDelay) }
            let candidate: SBXPCConnection
            if let connection, !connection.isInvalidated {
                // The daemon exited and XPC relaunches it on the next send; it needs a barrier again.
                candidate = connection
            } else {
                guard simulator.isBooted else {
                    throw ISimError.commandFailed(command: "dtuhidd", message: "Simulator \(simulator.name) is not booted. Call boot_device first.")
                }
                do {
                    candidate = try SBXPCConnection(simulator: simulator, service: DTUHIDMessage.service)
                } catch {
                    throw ISimError.commandFailed(command: "dtuhidd", message: error.localizedDescription)
                }
            }
            let interruptions = candidate.interruptions
            switch await Self.probe(candidate) {
            case .answered:
                try? await Task.sleep(for: Self.activationTail)
                connection = candidate
                confirmedInterruptions = interruptions
                return candidate
            case .closed:
                // The simulator rebooted or the daemon is gone: a new lookup can work right away.
                waitBeforeRetry = false
                lastProblem = "connection closed"
            case .silent:
                // launchd may be holding a crashed daemon's restart.
                waitBeforeRetry = true
                lastProblem = "no answer within \(Int(Self.probeTimeout)) s"
            }
            // A cancelled XPC connection cannot be resumed; the next attempt looks the service up again.
            candidate.cancel()
            connection = nil
        }
        throw ISimError.commandFailed(
            command: "dtuhidd",
            message: "The simulator's HID service did not respond (\(lastProblem), \(Self.probeAttempts) attempts). "
                + "It may still be booting; try again, or reboot the simulator with reboot_device.")
    }

    enum ProbeResult {
        case answered
        /// XPC reported the connection broken.
        case closed
        /// No reply before the timeout.
        case silent
    }

    /// Sends a barrier and waits for the reply.
    static func probe(_ connection: SBXPCConnection) async -> ProbeResult {
        await withCheckedContinuation { continuation in
            connection.sendMessage(DTUHIDMessage.barrier.xpcObject(), timeout: probeTimeout) { reply in
                guard let reply else { return continuation.resume(returning: .silent) }
                continuation.resume(returning: xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? .answered : .closed)
            }
        }
    }
}
