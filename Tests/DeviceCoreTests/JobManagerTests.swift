import DeviceCore
import Foundation
import ProcessKit
import Testing

/// Jobs run real shell scripts: the point is how output is read while it grows and how jobs stop.
struct JobManagerTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isim-jobs-\(UUID().uuidString)", isDirectory: true)
    let device = Device(udid: "SIM-1", name: "iPhone 16 Pro", kind: .simulator, state: .booted)

    private func manager() -> JobManager {
        JobManager(launcher: ProcessRunner(killGracePeriod: .milliseconds(500)), directory: directory)
    }

    private func shell(_ script: String, noise: [String] = [], ready: String? = nil) -> BackgroundCommand {
        BackgroundCommand(executable: "/bin/sh", arguments: ["-c", script], noise: noise, readyMarker: ready)
    }

    /// Reads until the job has ended, so all of a quick script's output is there.
    private func finished(_ jobs: JobManager, _ id: String) async throws {
        for _ in 0..<100 where try await jobs.job(id).isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func readsFromWhereTheLastReadStopped() async throws {
        let jobs = manager()
        let job = try await jobs.start(.log, command: shell("printf 'one\\ntwo\\nthree\\n'"), device: device, title: "test")
        try await finished(jobs, job.id)
        #expect(job.id == "log-1")
        let first = try await jobs.read(job.id, maxLines: 2)
        #expect(first.lines == ["one", "two"])
        #expect(first.hasMore)
        let second = try await jobs.read(job.id, maxLines: 10)
        #expect(second.lines == ["three"])
        #expect(!second.hasMore)
        // A cursor reads again from there.
        let again = try await jobs.read(job.id, cursor: first.cursor, maxLines: 10)
        #expect(again.lines == ["three"])
    }

    @Test func grepCountsWhatItPassesOver() async throws {
        let jobs = manager()
        let job = try await jobs.start(.log, command: shell("printf 'Error one\\nfine\\nerror two\\n'"), device: device, title: "test")
        try await finished(jobs, job.id)
        let chunk = try await jobs.read(job.id, maxLines: 10, grep: "ERROR")
        #expect(chunk.lines == ["Error one", "error two"])
        #expect(chunk.skipped == 1)
    }

    @Test func dropsNoiseAndTheCommandLine() async throws {
        let jobs = manager()
        let job = try await jobs.start(
            .log, command: shell("echo 'Filtering the log data'; echo entry", noise: ["Filtering"]), device: device, title: "test")
        try await finished(jobs, job.id)
        #expect(try await jobs.read(job.id, maxLines: 10).lines == ["entry"])
    }

    @Test func anUnfinishedLineWaitsWhileTheJobRuns() async throws {
        let jobs = manager()
        let job = try await jobs.start(.log, command: shell("printf 'done\\npart'; sleep 5"), device: device, title: "test")
        try await Task.sleep(for: .milliseconds(300))
        let chunk = try await jobs.read(job.id, maxLines: 10)
        #expect(chunk.lines == ["done"])
        #expect(!chunk.hasMore)
        let stopped = try #require(await jobs.stop(job.id))
        #expect(!stopped.isRunning)
        #expect(try await jobs.read(job.id, maxLines: 10).lines == ["part"])
    }

    @Test func waitsForTheReadyMarker() async throws {
        let jobs = manager()
        let job = try await jobs.start(.recording, command: shell("sleep 0.3; echo 'Recording started'; sleep 5", ready: "Recording started"),
                                       device: device, title: "recording")
        #expect(job.isRunning)
        #expect(try await jobs.read(job.id, maxLines: 10).lines == ["Recording started"])
        await jobs.stopAll()
        #expect(try await !jobs.job(job.id).isRunning)
    }

    @Test func failsWhenTheCommandExitsBeforeItIsReady() async throws {
        let jobs = manager()
        await #expect(throws: ISimError.self) {
            try await jobs.start(.recording, command: shell("echo 'No such display' >&2; exit 3", ready: "Recording started"),
                                 device: device, title: "recording")
        }
    }

    /// Recorders finish their file on SIGINT, so a recording is interrupted rather than terminated.
    @Test func recordingsAreInterrupted() async throws {
        let jobs = manager()
        let script = "trap 'echo finished; exit 0' INT; echo 'Recording started'; while true; do sleep 0.1; done"
        let job = try await jobs.start(.recording, command: shell(script, ready: "Recording started"), device: device, title: "recording")
        let stopped = try #require(await jobs.stop(job.id, timeout: .seconds(5)))
        #expect(stopped.exitStatus == 0)
        #expect(try await jobs.read(job.id, maxLines: 10).lines.contains("finished"))
    }

    @Test func unknownJobListsTheKnownOnes() async throws {
        let jobs = manager()
        _ = try await jobs.start(.console, command: shell("true"), device: device, title: "console")
        await #expect(throws: ISimError.notFound("No job \"log-9\". Jobs: console-1.")) { try await jobs.job("log-9") }
    }
}
