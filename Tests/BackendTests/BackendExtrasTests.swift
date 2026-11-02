import CoreGraphics
import DeviceCore
import DevicectlBackend
import Foundation
import ProcessKit
@testable import SimBridgeBackend
import SimctlBackend
import TestSupport
import Testing
import XPC

/// Logs, recordings, crash reports, app data, locale and the other simulator extras.
struct SimctlExtrasTests {
    let runner = ScriptedRunner()
    let reports = FileManager.default.temporaryDirectory.appendingPathComponent("isim-reports-\(UUID().uuidString)", isDirectory: true)
    var simctl: SimctlBackend { SimctlBackend(runner: runner, diagnosticReports: reports) }

    @Test func recordingWaitsForTheFirstFrame() {
        let command = simctl.recordingCommand(udid: "SIM-1", path: "/tmp/a.mov", codec: .h264)
        #expect(command.arguments == ["simctl", "io", "SIM-1", "recordVideo", "--codec=h264", "--force", "/tmp/a.mov"])
        #expect(command.readyMarker == "Recording started")
        #expect(simctl.videoFileExtension == "mov")
    }

    @Test func logStreamUsesThePredicateAndDropsLogsOwnLines() {
        let command = simctl.logStreamCommand(udid: "SIM-1", filter: LogFilter(process: "SpringBoard", level: .info))
        #expect(command.arguments == [
            "simctl", "spawn", "SIM-1", "log", "stream", "--style", "compact", "--level", "info", "--predicate", #"process == "SpringBoard""#,
        ])
        #expect(command.noise.contains("Timestamp "))
    }

    @Test func queryAsksForInfoAndDebugEntries() async throws {
        runner.on("log show", stdout: """
            getpwuid_r did not find a match for uid 501
            Filtering the log data using "process == "X""
            Timestamp               Ty Process[PID:TID]
            2026-10-23 12:27:08.585 I  X[3511:74561b] [dev.x:lab] hello
            """)
        let lines = try await simctl.queryLogs(udid: "SIM-1", filter: LogFilter(process: "X"), last: .seconds(90))
        #expect(lines == ["2026-10-23 12:27:08.585 I  X[3511:74561b] [dev.x:lab] hello"])
        #expect(runner.calls.last?.commandLine == #"simctl spawn SIM-1 log show --style compact --last 90s --info --debug --predicate process == "X""#)
    }

    @Test func consoleLaunchGoesThroughAPseudoTerminal() {
        let command = simctl.consoleCommand(udid: "SIM-1", bundleId: "dev.x", options: LaunchOptions(arguments: ["-lab"], environment: ["A": "1"]))
        #expect(command.arguments == ["simctl", "launch", "--console-pty", "--terminate-running-process", "SIM-1", "dev.x", "-lab"])
        #expect(command.environment == ["SIMCTL_CHILD_A": "1"])
        #expect(command.readyMarker == nil)
        #expect(command.noise.first == #"dev\.x: \d+$"#)
    }

    @Test func listsOnlyThisSimulatorsReports() async throws {
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: reports) }
        let crash = try fixture("simulator-crash.ips")
        try crash.write(to: reports.appendingPathComponent("ISimTestApp-2026-10-23-123148.ips"))
        try String(decoding: crash, as: UTF8.self).replacingOccurrences(of: "8D408511-219C-42B6-98FB-C0ED9F56836F", with: "OTHER-SIM")
            .write(to: reports.appendingPathComponent("ISimTestApp-2026-10-23-120000.ips"), atomically: true, encoding: .utf8)
        try #"{"app_name":"Finder","platform":1}"#.write(to: reports.appendingPathComponent("Finder-2026-10-23-110000.ips"), atomically: true, encoding: .utf8)

        let entries = try await simctl.crashReports(udid: "8D408511-219C-42B6-98FB-C0ED9F56836F")
        #expect(entries.map(\.name) == ["ISimTestApp-2026-10-23-123148.ips"])
        #expect(entries.first?.bundleId == "dev.isimmcp.testapp")
        #expect(entries.first?.kind == .crash)
        let data = try await simctl.crashReport(udid: "8D408511-219C-42B6-98FB-C0ED9F56836F", name: "ISimTestApp-2026-10-23-123148.ips")
        #expect(data == crash)
        await #expect(throws: ISimError.self) {
            try await simctl.crashReport(udid: "8D408511-219C-42B6-98FB-C0ED9F56836F", name: "ISimTestApp-2026-10-23-120000.ips")
        }
    }

    @Test func containerFilesAreReadOnTheMac() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isim-container-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents/deep/deeper"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hi".write(to: root.appendingPathComponent("Documents/hello.txt"), atomically: true, encoding: .utf8)
        runner.on("get_app_container SIM-1 dev.x data", stdout: root.path + "\n")

        let files = try await simctl.listFiles(udid: "SIM-1", bundleId: "dev.x", container: .data, subpath: "Documents", depth: 2)
        #expect(files.map(\.path) == ["Documents/deep", "Documents/deep/deeper", "Documents/hello.txt"])
        #expect(files.first { $0.path == "Documents/hello.txt" }?.size == 2)
        let shallow = try await simctl.listFiles(udid: "SIM-1", bundleId: "dev.x", container: .data, subpath: "", depth: 1)
        #expect(shallow.map(\.path) == ["Documents"])

        let source = root.appendingPathComponent("upload.json")
        try "{}".write(to: source, atomically: true, encoding: .utf8)
        try await simctl.writeFile(udid: "SIM-1", bundleId: "dev.x", container: .data, path: "Documents/new/fixture.json", from: source)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("isim-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try await simctl.readFile(udid: "SIM-1", bundleId: "dev.x", container: .data, path: "/Documents/new/fixture.json", to: copy)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "{}")
        await #expect(throws: ISimError.self) {
            try await simctl.readFile(udid: "SIM-1", bundleId: "dev.x", container: .data, path: "Documents", to: copy)
        }
    }

    @Test func userDefaultsGoThroughDefaultsInsideTheSimulator() async throws {
        runner.on("get_app_container SIM-1 dev.x data", stdout: "/C/Data\n")
        runner.on("get_app_container SIM-1 dev.x group.shared", stdout: "/C/Group\n")
        runner.on("defaults delete", exitCode: 1, stderr: "Domain (…) not found.")
        runner.on("defaults", stdout: "<plist/>")
        try await simctl.writeUserDefault(udid: "SIM-1", bundleId: "dev.x", suite: nil, key: "flag", value: "<true/>")
        _ = try await simctl.userDefaults(udid: "SIM-1", bundleId: "dev.x", suite: "group.shared")
        await #expect(throws: ISimError.notFound("dev.x has no default \"gone\".")) {
            try await simctl.writeUserDefault(udid: "SIM-1", bundleId: "dev.x", suite: nil, key: "gone", value: nil)
        }
        let commands = runner.calls.map(\.commandLine).filter { $0.contains("defaults") }
        #expect(commands == [
            "simctl spawn SIM-1 defaults write /C/Data/Library/Preferences/dev.x flag <true/>",
            "simctl spawn SIM-1 defaults export /C/Group/Library/Preferences/group.shared -",
            "simctl spawn SIM-1 defaults delete /C/Data/Library/Preferences/dev.x gone",
        ])
    }

    @Test func localeIsReadAndWrittenInTheGlobalDomain() async throws {
        runner.on("defaults export -g", stdout: """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
            <key>AppleLanguages</key><array><string>en-UA</string><string>uk-UA</string></array>
            <key>AppleLocale</key><string>en_UA</string></dict></plist>
            """)
        runner.on("defaults write")
        #expect(try await simctl.locale(udid: "SIM-1") == DeviceLocale(languages: ["en-UA", "uk-UA"], locale: "en_UA"))
        try await simctl.setLocale(udid: "SIM-1", languages: ["de-DE", "en-UA"], locale: "de_DE")
        #expect(runner.calls.map(\.commandLine).suffix(2) == [
            "simctl spawn SIM-1 defaults write -g AppleLanguages -array de-DE en-UA",
            "simctl spawn SIM-1 defaults write -g AppleLocale -string de_DE",
        ])
    }

    @Test func simulatorCommands() async throws {
        runner.on("simctl clone", stdout: "NEW-UDID\n")
        runner.on("simctl")
        #expect(try await simctl.clone(udid: "SIM-1", name: "Snapshot") == "NEW-UDID")
        try await simctl.rename(udid: "SIM-1", name: "Renamed")
        try await simctl.addCertificate(udid: "SIM-1", path: "/ca.pem", trustedRoot: true)
        try await simctl.resetKeychain(udid: "SIM-1")
        try await simctl.shake(udid: "SIM-1")
        try await simctl.syncICloud(udid: "SIM-1")
        let spawned = try await simctl.spawn(udid: "SIM-1", executable: "defaults", arguments: ["read", "-g"], timeout: .seconds(5))
        #expect(spawned.succeeded)
        #expect(runner.calls.map(\.commandLine) == [
            "simctl clone SIM-1 Snapshot", "simctl rename SIM-1 Renamed", "simctl keychain SIM-1 add-root-cert /ca.pem",
            "simctl keychain SIM-1 reset", "simctl spawn SIM-1 notifyutil -p com.apple.UIKit.SimulatorShake", "simctl icloud_sync SIM-1",
            "simctl spawn SIM-1 defaults read -g",
        ])
    }
}

struct DevicectlExtrasTests {
    let runner = ScriptedRunner()
    var devicectl: DevicectlBackend { DevicectlBackend(runner: runner) }

    private func success(_ result: [String: Any] = [:]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": result])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func filesAreNamedFromTheContainerRoot() throws {
        let result = try DevicectlParser.result(from: ProcessResult(exitCode: 0, stdout: try fixture("devicectl-files.json")), command: "devicectl")
        let files = DevicectlParser.files(from: result, under: "Documents")
        #expect(files.map(\.path) == ["Documents/sub", "Documents/sub/up.txt"])
        #expect(files[0].isDirectory)
        #expect(files[0].size == nil)
        #expect(files[1].size == 12)
        #expect(files[1].modified != nil)
    }

    @Test func listsCrashReportsByName() async throws {
        runner.on("systemCrashLogs", stdout: try fixtureString("devicectl-crashlogs.json"))
        let reports = try await devicectl.crashReports(udid: "PHONE-1")
        #expect(reports.map(\.name) == [
            "JetsamEvent-2026-10-22-200453.ips", "ISimAgentRunner-Runner-2026-10-22-191632.ips", "logd.diskwrites_resource-2026-10-20-175223.ips",
        ])
        #expect(reports.map(\.kind) == [.jetsam, .crash, .resource])
        #expect(reports[1].process == "ISimAgentRunner-Runner")
    }

    @Test func listingStopsAtTheDepth() async throws {
        runner.on("device info files", stdout: try fixtureString("devicectl-files.json"))
        let files = try await devicectl.listFiles(udid: "PHONE-1", bundleId: "dev.x", container: .data, subpath: "Documents", depth: 1)
        #expect(files.map(\.path) == ["Documents/sub"])
        #expect(runner.calls.last?.commandLine.hasSuffix(
            "device info files --device PHONE-1 --domain-type appDataContainer --domain-identifier dev.x --subdirectory Documents --no-recurse") == true)
    }

    @Test func groupContainersUseTheirIdentifier() async throws {
        runner.on("copy to", stdout: success())
        try await devicectl.writeFile(udid: "PHONE-1", bundleId: "dev.x", container: .group("group.dev.x"), path: "a/b.txt", from: URL(fileURLWithPath: "/tmp/b.txt"))
        #expect(runner.calls.last?.commandLine.hasSuffix(
            "device copy to --device PHONE-1 --domain-type appGroupDataContainer --domain-identifier group.dev.x --source /tmp/b.txt --destination a/b.txt") == true)
    }

    @Test func preferencesThatWereNeverWrittenAreEmpty() async throws {
        runner.on("device info files", stdout: success(["files": []]))
        let data = try await devicectl.userDefaults(udid: "PHONE-1", bundleId: "dev.x", suite: nil)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(plist?.isEmpty == true)
    }

    @Test func memoryWarningNeedsAProcess() async throws {
        runner.on("sendMemoryWarning", stdout: success())
        try await devicectl.sendMemoryWarning(udid: "PHONE-1", pid: 42)
        #expect(runner.calls.last?.commandLine.hasSuffix("device process sendMemoryWarning --device PHONE-1 --pid 42") == true)
        await #expect(throws: ISimError.self) { try await devicectl.sendMemoryWarning(udid: "PHONE-1", pid: nil) }
    }

    @Test func consoleLaunchKeepsOnlyTheAppsOutput() {
        let command = devicectl.consoleCommand(udid: "PHONE-1", bundleId: "dev.x", options: LaunchOptions(arguments: ["-lab"]))
        #expect(command.arguments == [
            "devicectl", "--quiet", "device", "process", "launch", "--console", "--device", "PHONE-1", "--terminate-existing", "dev.x", "--", "-lab",
        ])
        #expect(command.readyMarker == nil)
    }
}

struct CrashReportFixtureTests {
    @Test func explainsASimulatorCrash() throws {
        let report = try CrashReport.parse(try fixture("simulator-crash.ips"))
        #expect(report.process == "ISimTestApp")
        #expect(report.bundleId == "dev.isimmcp.testapp")
        #expect(report.version == "1.0 (1)")
        #expect(report.exception == "EXC_BREAKPOINT (SIGTRAP), codes 0x0000000000000001, 0x00000001c16c415c")
        #expect(report.termination == "SIGNAL 5 Trace/BPT trap: 5")
        #expect(report.crashedThread == 0)
        #expect(report.crashedThreadName == "com.apple.main-thread")
        #expect(report.frames.first?.symbol == "_assertionFailure(_:_:file:line:flags:)")
        #expect(report.frames[1] == CrashReport.Frame(image: "ISimTestApp", symbol: "closure #6 in closure #1 in LabView.body.getter", offset: 176))
    }
}

struct TwoFingerHIDTests {
    @Test func secondFingerIsPointTwo() throws {
        let message = DTUHIDMessage.touch(CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5), phase: .move).xpcObject()
        let payload = try #require(xpc_dictionary_get_dictionary(message, "payload"))
        let second = try #require(xpc_dictionary_get_dictionary(payload, "pointTwo"))
        #expect(xpc_dictionary_get_double(second, "x") == 0.8)
        #expect(xpc_dictionary_get_double(try #require(xpc_dictionary_get_dictionary(payload, "pointOne")), "x") == 0.2)
    }

    @Test func pathsWaitBetweenSamples() {
        let a = CGPoint(x: 0.1, y: 0.1), b = CGPoint(x: 0.2, y: 0.2)
        #expect(HIDScript.path([(a, .zero), (b, .milliseconds(16))]) == [
            .send(.touch(a, phase: .start)), .wait(.milliseconds(16)), .send(.touch(b, phase: .move)), .send(.touch(b, phase: .end)),
        ])
        #expect(HIDScript.twoFingers([(a, b, .zero), (b, a, .milliseconds(20))]) == [
            .send(.touch(a, b, phase: .start)), .wait(.milliseconds(20)), .send(.touch(b, a, phase: .move)), .send(.touch(b, a, phase: .end)),
        ])
    }
}
