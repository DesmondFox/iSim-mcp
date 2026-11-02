import DeviceCore
import Foundation

/// Finding and describing the background jobs of log captures, app consoles and recordings.
extension ToolContext {
    /// The job a tool acts on: `job_id`, or the only (running) job of these kinds.
    func jobID(_ arguments: ToolArguments, kinds: Set<JobManager.Kind>, running: Bool) async throws -> String {
        if let id = try arguments.string("job_id").flatMap({ $0.isEmpty ? nil : $0 }) {
            let job = try await jobs.job(id)
            guard kinds.contains(job.kind) else {
                throw ISimError.invalidArgument("\(id) is a \(job.kind.rawValue) job; this tool works on "
                    + kinds.map(\.rawValue).sorted().joined(separator: " and ") + " jobs.")
            }
            return id
        }
        let candidates = await jobs.all().filter { kinds.contains($0.kind) && (!running || $0.isRunning) }
        let what = kinds == [.recording] ? "recording" : "log capture"
        switch candidates.count {
        case 1:
            return candidates[0].id
        case 0:
            throw ISimError.notFound("No \(running ? "running " : "")\(what). "
                + (kinds == [.recording] ? "Start one with start_recording." : "Start one with start_log_capture or launch_app(capture_output: true)."))
        default:
            throw ISimError.invalidArgument("Several jobs could be meant; pass `job_id`:\n"
                + candidates.map { "  " + JobText.describe($0) }.joined(separator: "\n"))
        }
    }
}

enum JobText {
    /// "log-1: unified log of dev.example.app on "iPhone 16 Pro", running for 42 s"
    static func describe(_ job: JobManager.Job) -> String {
        let seconds = Int((job.endedAt ?? Date()).timeIntervalSince(job.startedAt))
        let state = if job.isRunning {
            "running for \(seconds) s"
        } else if job.wasStopped {
            "stopped after \(seconds) s"
        } else {
            "ended after \(seconds) s" + (job.exitStatus.map { $0 == 0 ? "" : " (exit status \($0))" } ?? "")
        }
        return "\(job.id): \(job.title) on \"\(job.deviceName)\", \(state)"
    }
}
