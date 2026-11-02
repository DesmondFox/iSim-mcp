import APNsBackend
import CryptoKit
import DeviceCore
import Foundation
@testable import ISimMCP
import MCP
import ProcessKit
import TestSupport
import Testing

/// Runs a shell script in place of whatever command a job asks for, and remembers what was asked.
final class ScriptLauncher: BackgroundLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let script: String
    private(set) var commands: [[String]] = []

    init(_ script: String) {
        self.script = script
    }

    func launch(_ executable: String, _ arguments: [String], environment: [String: String], log: URL) throws -> any BackgroundProcess {
        lock.withLock { commands.append([executable] + arguments) }
        return try ProcessRunner(killGracePeriod: .milliseconds(300)).launch("/bin/sh", ["-c", script], environment: [:], log: log)
    }
}

/// Answers APNs requests with success.
private final class AcceptingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2", headerFields: ["apns-id": "ID-1"])!)
    }
}

struct LogAndDataToolTests {
    let runner = ScriptedRunner()
    let jobs = FileManager.default.temporaryDirectory.appendingPathComponent("isim-tool-jobs-\(UUID().uuidString)", isDirectory: true)

    init() {
        runner.on("simctl list devices", stdout: """
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {"udid": "SIM-1", "name": "iPhone 16 Pro", "state": "Booted", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"}
            ]}}
            """)
        runner.on("list devices", stdout: """
            {"info": {"outcome": "success"}, "result": {"devices": [
              {"hardwareProperties": {"reality": "physical", "platform": "iOS", "udid": "PHONE-1", "marketingName": "iPhone 14 Plus"},
               "deviceProperties": {"name": "Test iPhone", "osVersionNumber": "27.0.1", "developerModeStatus": "enabled"},
               "connectionProperties": {"transportType": "wired", "tunnelState": "connected"}}
            ]}}
            """)
        runner.on("defaults read com.apple.Accessibility ApplicationAccessibilityEnabled", stdout: "1\n")
    }

    private func context(launcher: (any BackgroundLaunching)? = nil, reports: URL? = nil, apns: APNsCredentials? = nil,
                         transport: (any HTTPTransport)? = nil) -> ToolContext {
        ToolContext(
            runner: runner, xcode: .success(XcodeEnvironment(developerDir: "/Xcode.app/Contents/Developer", version: "27.1", build: nil)),
            agentPaths: nil, launcher: launcher, jobDirectory: jobs, diagnosticReports: reports, apns: apns, apnsTransport: transport)
    }

    private func call(_ name: String, _ arguments: [String: Value], _ context: ToolContext, device: String? = "SIM-1") async throws -> CallTool.Result {
        try await ISimServer.makeRegistry(toolsets: Set(Toolset.allCases))
            .call(name, arguments: arguments.merging(device.map { ["device": .string($0)] } ?? [:]) { current, _ in current }, context: context)
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    // MARK: Logs and output

    @Test func capturesAnAppsUnifiedLog() async throws {
        runner.on("simctl appinfo SIM-1 dev.x", stdout: #"{CFBundleExecutable = "XApp"; CFBundleIdentifier = "dev.x";}"#)
        let launcher = ScriptLauncher("echo 'Filtering the log data using x'; echo 'hello from x'; echo 'error in x'; sleep 5")
        let context = context(launcher: launcher)
        let start = try await call("start_log_capture", ["bundle_id": "dev.x", "level": "info"], context)
        #expect(text(start).hasPrefix("Capturing the unified log of dev.x on \"iPhone 16 Pro\" (level info) as job log-1."))
        #expect(launcher.commands.first?.suffix(4) == ["--level", "info", "--predicate", #"(process == "XApp" OR subsystem == "dev.x")"#])

        try await Task.sleep(for: .milliseconds(300))
        let read = try await call("read_log_capture", ["grep": "ERROR"], context, device: nil)
        #expect(text(read).hasPrefix("error in x\n— log-1: unified log of dev.x on \"iPhone 16 Pro\", running for"))
        #expect(text(read).contains("1 line(s) without \"ERROR\" passed over"))
        let again = try await call("read_log_capture", ["cursor": 0], context, device: nil)
        #expect(text(again).hasPrefix("hello from x\nerror in x\n"))

        let stop = try await call("stop_log_capture", [:], context, device: nil)
        #expect(text(stop).hasPrefix("Stopped log-1: unified log of dev.x on \"iPhone 16 Pro\", stopped after"))
        let none = try await call("stop_log_capture", [:], context, device: nil)
        #expect(none.isError == true)
    }

    @Test func capturesAnIPhoneAppsLogWithoutRelaunchingIt() async throws {
        runner.on("device info apps --device PHONE-1", stdout: """
            {"info": {"outcome": "success"}, "result": {"apps": [
              {"bundleIdentifier": "dev.x", "name": "X", "builtByDeveloper": true,
               "url": "file:///private/var/containers/Bundle/Application/A845C876/Runner.app/"}
            ]}}
            """)
        let launcher = ScriptLauncher(#"echo 'isim-mcp: streaming the unified log of "Test iPhone" (USB)'; "#
            + "echo '2026-10-26 16:48:50.629 I  Runner[14510:4a6c96] [dev.x:lab] hello from x'; sleep 5")
        let context = context(launcher: launcher)
        let start = try await call("start_log_capture", ["bundle_id": "dev.x"], context, device: "PHONE-1")
        #expect(text(start).hasPrefix("Capturing the unified log of dev.x on \"Test iPhone\" (level debug) as job log-1."))
        let command = try #require(launcher.commands.first)
        #expect(command.dropFirst() == ["device-log", "--udid", "PHONE-1", "--bundle-id", "dev.x", "--executable", "Runner", "--level", "debug"])
        #expect(!runner.calls.contains { $0.commandLine.contains("process launch") })

        try await Task.sleep(for: .milliseconds(300))
        let read = try await call("read_log_capture", [:], context, device: nil)
        #expect(text(read).hasPrefix("2026-10-26 16:48:50.629 I  Runner[14510:4a6c96] [dev.x:lab] hello from x\n— log-1"))
        await context.jobs.stopAll()
    }

    @Test func queriesAnIPhonesLogArchive() async throws {
        runner.on("device-log --udid PHONE-1 --archive")
        runner.on("show --archive", stdout: "2026-10-26 16:49:42.044 F  audiomxd[8769:4a6166] [com.apple.defaults:User Defaults] fault\n")
        let result = try await call("query_logs", ["predicate": #"logType == "fault""#, "last": "2m"], context(), device: "PHONE-1")
        #expect(text(result) == "1 entry of the predicate in the last 2m:\n2026-10-26 16:49:42.044 F  audiomxd[8769:4a6166] [com.apple.defaults:User Defaults] fault")
        #expect(runner.calls.last?.commandLine.hasSuffix(#"--last 120s --info --debug --predicate (logType == "fault")"#) == true)
    }

    @Test func logCaptureNeedsAFilter() async throws {
        let result = try await call("start_log_capture", [:], context(launcher: ScriptLauncher("true")))
        #expect(text(result).hasPrefix("Pass bundle_id, process, subsystem or predicate"))
    }

    @Test func launchWithCapturedOutputReportsThePid() async throws {
        let launcher = ScriptLauncher("echo 'ISimTestApp: lab opened'; echo 'objc[4242]: Class AXLoader is implemented in both A and B.'; sleep 5")
        runner.on("launchctl list", stdout: "PID\tStatus\tLabel\n4242\t0\tUIKitApplication:dev.x[1a2b][rb-legacy]\n")
        let context = context(launcher: launcher)
        let result = try await call("launch_app", ["bundle_id": "dev.x", "capture_output": true], context)
        #expect(text(result).hasPrefix("Launched dev.x (pid 4242) on \"iPhone 16 Pro\" with its stdout and stderr going to job console-1."))
        #expect(launcher.commands.first?.contains("--console-pty") == true)
        try await Task.sleep(for: .milliseconds(200))
        let read = try await call("read_log_capture", ["job_id": "console-1"], context, device: nil)
        #expect(text(read).hasPrefix("ISimTestApp: lab opened\n— console-1"))
        await context.jobs.stopAll()
    }

    @Test func queryKeepsTheLatestLines() async throws {
        runner.on("log show", stdout: (1...5).map { "line \($0)" }.joined(separator: "\n"))
        let result = try await call("query_logs", ["process": "SpringBoard", "last": "2m", "max_lines": 2], context())
        #expect(text(result) == "5 entries of process SpringBoard in the last 2m, the latest 2:\nline 4\nline 5")
        #expect(runner.calls.last?.commandLine.contains("--last 120s") == true)
    }

    @Test func recordingNeedsASimulator() async throws {
        let result = try await call("start_recording", [:], context(), device: "PHONE-1")
        #expect(text(result).hasPrefix("start_recording is not available on physical devices. iPhones do not offer screen recording"))
    }

    // MARK: Crash reports

    @Test func listsAndExplainsCrashReports() async throws {
        let reports = FileManager.default.temporaryDirectory.appendingPathComponent("isim-tool-reports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: reports) }
        let header = #"{"app_name":"Demo","bundleID":"com.example.demo","bug_type":"309","platform":7}"#
        let body = #"{"procPath":"\/Devices\/SIM-1\/data\/Demo.app\/Demo","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"faultingThread":0,"threads":[{"frames":[{"imageIndex":0,"symbol":"main","symbolLocation":12}]}],"usedImages":[{"name":"Demo"}]}"#
        try (header + "\n" + body).write(to: reports.appendingPathComponent("Demo-2026-10-23-101010.ips"), atomically: true, encoding: .utf8)
        let context = context(reports: reports)

        let list = try await call("list_crash_reports", ["bundle_id": "com.example.demo"], context)
        #expect(text(list).hasPrefix("Demo-2026-10-23-101010.ips — Demo (com.example.demo), 20"))
        let other = try await call("list_crash_reports", ["bundle_id": "com.example.other"], context)
        #expect(text(other) == "No crash reports of com.example.other on \"iPhone 16 Pro\".")
        let report = try await call("get_crash_report", ["name": "Demo-2026-10-23-101010.ips"], context)
        #expect(text(report) == """
            Demo (com.example.demo) crashed
            Exception: EXC_BAD_ACCESS (SIGSEGV)
            Crashed thread 0:
              0  Demo  main + 12
            """)
    }

    // MARK: App data

    @Test func writesTypedUserDefaults() async throws {
        runner.on("get_app_container SIM-1 dev.x data", stdout: "/C\n")
        runner.on("defaults write")
        let context = context()
        let set = try await call("write_user_defaults", ["bundle_id": "dev.x", "key": "flags", "value": ["beta": true, "level": 3]], context)
        #expect(text(set) == "Set \"flags\" in the UserDefaults of dev.x to <dict><key>beta</key><true/><key>level</key><integer>3</integer></dict>.")
        _ = try await call("write_user_defaults", ["bundle_id": "dev.x", "key": "count", "value": "7", "type": "integer"], context)
        #expect(runner.calls.last?.arguments.last == "<integer>7</integer>")
        let bad = try await call("write_user_defaults", ["bundle_id": "dev.x", "key": "count", "value": "seven", "type": "integer"], context)
        #expect(text(bad) == "`value` is not an integer.")
    }

    @Test func readsUserDefaultsAsJSON() async throws {
        runner.on("get_app_container SIM-1 dev.x data", stdout: "/C\n")
        runner.on("defaults export", stdout: """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>greeting</key><string>Hi</string><key>launchCount</key><integer>2</integer></dict></plist>
            """)
        let context = context()
        let all = try await call("read_user_defaults", ["bundle_id": "dev.x"], context)
        #expect(text(all) == "UserDefaults of dev.x (2 key(s)):\n{\n  \"greeting\" : \"Hi\",\n  \"launchCount\" : 2\n}")
        let one = try await call("read_user_defaults", ["bundle_id": "dev.x", "key": "greeting"], context)
        #expect(text(one) == "greeting = \"Hi\"")
        let missing = try await call("read_user_defaults", ["bundle_id": "dev.x", "key": "nope"], context)
        #expect(text(missing) == "dev.x has no default \"nope\". Keys: greeting, launchCount")
    }

    @Test func showsFilesInTheirBestForm() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
        #expect(try text(DataTools.contents(of: plist, path: "x.plist", size: "1 KB", maxBytes: 100)) == "x.plist (1 KB, property list):\n{\n  \"a\" : 1\n}")
        #expect(try text(DataTools.contents(of: Data("hello".utf8), path: "a.txt", size: "5 bytes", maxBytes: 3)) == "a.txt (5 bytes):\nhel\n… [cut at 3 bytes]")
        #expect(try text(DataTools.contents(of: Data([0, 1, 2]), path: "a.bin", size: "3 bytes", maxBytes: 100)) == "a.bin (3 bytes, binary), base64:\nAAEC")
    }

    @Test func refusesPathsOutsideTheContainer() async throws {
        let result = try await call("read_container_file", ["bundle_id": "dev.x", "path": "../../etc/passwd"], context())
        #expect(text(result).hasPrefix("Paths must stay inside the container"))
    }

    // MARK: System

    @Test func localeChangeKeepsTheOtherLanguages() {
        let current = DeviceLocale(languages: ["en-UA", "de-DE", "uk-UA"], locale: "en_UA")
        let byLanguage = SystemTools.localeChange(current: current, language: "de-DE", region: nil, languages: [])
        #expect(byLanguage.languages == ["de-DE", "en-UA", "uk-UA"])
        #expect(byLanguage.locale == "de_DE")
        #expect(SystemTools.localeChange(current: current, language: "fr", region: nil, languages: []).locale == "fr_UA")
        #expect(SystemTools.localeChange(current: current, language: "zh-Hans", region: "CN", languages: []).locale == "zh-Hans_CN")
        let regionOnly = SystemTools.localeChange(current: current, language: nil, region: "GB", languages: [])
        #expect(regionOnly.languages == nil)
        #expect(regionOnly.locale == "en_GB")
    }

    @Test func pushToAnIPhoneGoesThroughAPNs() async throws {
        let key = FileManager.default.temporaryDirectory.appendingPathComponent("isim-tool-key-\(UUID().uuidString).p8")
        try P256.Signing.PrivateKey().pemRepresentation.write(to: key, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: key) }
        let transport = AcceptingTransport()
        let context = context(apns: APNsCredentials(keyPath: key.path, keyID: "K", teamID: "T"), transport: transport)
        let result = try await call("send_push", ["bundle_id": "dev.x", "device_token": "abcd", "payload": ["aps": ["alert": "Hi"]]], context, device: "PHONE-1")
        #expect(text(result).hasPrefix("APNs (sandbox) accepted the alert push to dev.x: apns-id ID-1."))
        #expect(transport.requests.first?.url?.lastPathComponent == "abcd")
    }

    @Test func pushThroughAPNsExplainsTheMissingKey() async throws {
        let result = try await call("send_push", ["bundle_id": "dev.x", "device_token": "abcd", "payload": ["aps": ["alert": "Hi"]]], context(), device: "PHONE-1")
        #expect(result.isError == true)
        #expect(text(result).hasPrefix("mode=apns needs an APNs auth key: restart the server with --apns-key-path"))
    }

    // MARK: Advanced

    @Test func rawCommandsReportTheirOutput() async throws {
        runner.on("simctl getenv", exitCode: 1, stderr: "Invalid device")
        let result = try await call("simctl_raw", ["args": ["getenv", "nope", "HOME"]], context(), device: nil)
        #expect(result.isError == true)
        #expect(text(result) == "$ simctl getenv nope HOME\nexit status 1\nstderr:\nInvalid device")
    }
}

struct ConsoleFailureTests {
    @Test func aLaunchThatEndsAtOnceIsAnError() async throws {
        let runner = ScriptedRunner()
        runner.on("simctl list devices", stdout: """
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {"udid": "SIM-1", "name": "iPhone 16 Pro", "state": "Booted", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"}
            ]}}
            """)
        runner.on("list devices", stdout: #"{"info": {"outcome": "success"}, "result": {"devices": []}}"#)
        runner.on("defaults read com.apple.Accessibility", stdout: "1\n")
        let context = ToolContext(
            runner: runner, xcode: .success(XcodeEnvironment(developerDir: "/X", version: "27.1", build: nil)), agentPaths: nil,
            launcher: ScriptLauncher("echo 'An error was encountered processing the command (code=4)'; exit 4"),
            jobDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("isim-console-\(UUID().uuidString)"))
        let result = try await ISimServer.makeRegistry(toolsets: [.apps])
            .call("launch_app", arguments: ["device": "SIM-1", "bundle_id": "dev.x", "capture_output": true], context: context)
        #expect(result.isError == true)
        #expect(result.content.description.contains("code=4"))
    }
}
