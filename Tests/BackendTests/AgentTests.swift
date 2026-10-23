import CoreGraphics
import DeviceCore
import Foundation
@testable import AgentBackend
import ProcessKit
import TestSupport
import Testing

struct AgentTreeTests {
    private func reply(bundle: String, _ tree: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["ok": true, "bundle_id": bundle, "tree": tree])
    }

    @Test func mapsElementTypesToSimBridgeRoles() throws {
        let data = try reply(bundle: "dev.isimmcp.testapp", [
            "type": "Application", "label": "iSim Test", "frame": [0, 0, 428, 926], "pid": 42, "children": [
                ["type": "StaticText", "label": "Welcome", "frame": [146, 374, 137, 41]],
                ["type": "TextField", "identifier": "username", "value": "Username", "placeholder": "Username",
                 "frame": [24, 431, 380, 34], "focused": true],
                ["type": "SecureTextField", "identifier": "password", "value": "••••", "frame": [24, 481, 380, 34]],
                ["type": "Toggle", "label": "Favorite", "value": "1", "frame": [20, 205, 388, 52], "enabled": false],
                ["type": "Other", "frame": [0, 0, 428, 926], "truncated": true],
                ["type": "Icon", "label": "Settings", "frame": [0, 0, 0, 0]],
            ],
        ])
        let root = try AgentTree.screen(from: data)
        #expect(root.label == "iSim Test")
        #expect(root.pid == 42)
        #expect(root.children.map(\.role) == ["text", "text_field", "secure_text_field", "switch", "element", "button"])
        // An empty field reports its placeholder as its value.
        #expect(root.children[1].value == nil)
        #expect(root.children[1].isFocused)
        #expect(root.children[2].value == "••••")
        #expect(root.children[3].displayValue == "on")
        #expect(!root.children[3].isEnabled)
        #expect(root.children[4].isTruncated)
    }

    @Test func springBoardHasNoLabel() throws {
        let root = try AgentTree.screen(from: try reply(bundle: "com.apple.springboard", ["type": "Application", "label": " ", "frame": [0, 0, 428, 926]]))
        #expect(root.label == nil)
        #expect(root.role == "application")
    }

    @Test func elementAtAPointIsTheSmallestThatSaysSomething() {
        let root = UIElement(role: "application", label: "Settings", frame: CGRect(x: 0, y: 0, width: 428, height: 926), children: [
            UIElement(role: "element", frame: CGRect(x: 0, y: 0, width: 428, height: 926), children: [
                UIElement(role: "button", label: "General", frame: CGRect(x: 20, y: 766, width: 388, height: 52), children: [
                    UIElement(role: "text", label: "General", frame: CGRect(x: 38, y: 778, width: 101, height: 28)),
                ]),
            ]),
        ])
        #expect(AgentTree.element(at: CGPoint(x: 50, y: 790), in: root)?.role == "text")
        #expect(AgentTree.element(at: CGPoint(x: 300, y: 790), in: root)?.role == "button")
        #expect(AgentTree.element(at: CGPoint(x: 300, y: 790), in: root)?.children.isEmpty == true)
        #expect(AgentTree.element(at: CGPoint(x: 300, y: 100), in: root)?.role == "element")
    }
}

struct AgentKeyTests {
    @Test func strokesBecomeKeyNamesOrCharacters() {
        func key(_ usage: UInt32, _ modifiers: [KeyModifier] = []) -> String? {
            HIDKeyboard.key(for: KeyStroke(usage: usage, modifiers: modifiers)).map { ($0.modifiers.map(\.rawValue) + [$0.key]).joined(separator: "+") }
        }
        #expect(key(0x28) == "return")
        #expect(key(0x2A) == "delete")
        #expect(key(0x50) == "left")
        #expect(key(0x04, [.command]) == "command+a")
        #expect(key(0x04, [.shift]) == "A")
        #expect(key(0x1E, [.shift]) == "!")
        #expect(key(0x27) == "0")
        #expect(key(0x2D, [.shift]) == "_")
        #expect(key(0x2D) == "-")
        #expect(key(0xFF) == nil)
    }
}

struct AgentBuildTests {
    @Test func readsTheTeamsSignedInToXcode() throws {
        let preferences: [String: Any] = ["IDEProvisioningTeamByIdentifier": [
            "B5156418": [
                ["isFreeProvisioningTeam": false, "teamID": "47A38L5NX6", "teamName": "BZZR, Inc.", "teamType": "Company"],
                ["isFreeProvisioningTeam": true, "teamID": "VYL36DLB34", "teamName": "Alexey Rott (Personal Team)"],
            ],
            "C0FFEE": [["isFreeProvisioningTeam": true, "teamID": "VYL36DLB34", "teamName": "Alexey Rott (Personal Team)"]],
        ]]
        let plist = try PropertyListSerialization.data(fromPropertyList: preferences, format: .xml, options: 0)
        #expect(DevelopmentTeam.parseXcodeTeams(plist) == [
            DevelopmentTeam(id: "47A38L5NX6", name: "BZZR, Inc.", isPersonal: false),
            DevelopmentTeam(id: "VYL36DLB34", name: "Alexey Rott (Personal Team)", isPersonal: true),
        ])
        #expect(DevelopmentTeam.parseXcodeTeams(Data()).isEmpty)
    }

    @Test func profilesMustListTheDeviceAndNotExpire() {
        let now = Date()
        let profile: [String: Any] = ["ProvisionedDevices": ["00008110-000244D21181401E"], "ExpirationDate": now.addingTimeInterval(86400)]
        #expect(AgentBuilder.profile(profile, allows: "00008110-000244d21181401e", at: now))
        #expect(!AgentBuilder.profile(profile, allows: "00008030-0000000000000000", at: now))
        #expect(!AgentBuilder.profile(profile, allows: "00008110-000244D21181401E", at: now.addingTimeInterval(86000)))
        #expect(AgentBuilder.profile(["ProvisionsAllDevices": true], allows: "anything", at: now))
    }

    @Test func explainsWhyTheAgentDidNotStart() {
        let untrusted = """
            Testing failed:
            \tISimAgentRunner-Runner encountered an error (The application could not be launched because the Developer App Certificate is not trusted.)
            """
        #expect(AgentFailure.explainStart(untrusted)?.hasPrefix("The iPhone does not trust the developer certificate") == true)
        #expect(AgentFailure.explainStart("Enable UI Automation in Settings")?.contains("Enable UI Automation") == true)
        #expect(AgentFailure.explainStart("Test Suite 'All tests' started") == nil)
        let build = "note: Using codesigning identity\nerror: No Account for Team \"AB12CD34EF\".\n** BUILD FAILED **"
        #expect(AgentFailure.explainBuild(build, target: .device(team: "AB12CD34EF")).hasPrefix("Xcode has no signed-in account for team AB12CD34EF"))
        #expect(AgentFailure.errorLines("error: one\nfine\nerror: one\nerror: two") == "error: one error: two")
    }

    @Test func fingerprintFollowsTheSourcesAndXcode() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("xcuserdata"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: source.appendingPathComponent("Agent.swift"))
        try Data("ignored".utf8).write(to: source.appendingPathComponent("xcuserdata/state"))
        let paths = AgentPaths(source: source, cache: source.appendingPathComponent("cache"))
        let xcode = XcodeEnvironment(developerDir: "/Xcode.app/Contents/Developer", version: "27.1", build: "27B1")
        let builder = AgentBuilder(runner: ScriptedRunner(), paths: paths, xcode: xcode)
        let first = try builder.fingerprint()
        try Data("changed".utf8).write(to: source.appendingPathComponent("xcuserdata/state"))
        #expect(try builder.fingerprint() == first)
        try Data("two".utf8).write(to: source.appendingPathComponent("Agent.swift"))
        #expect(try builder.fingerprint() != first)
        var newer = xcode
        newer.build = "27B2"
        #expect(try AgentBuilder(runner: ScriptedRunner(), paths: paths, xcode: newer).fingerprint() != builder.fingerprint())
    }
}

struct AgentTeamTests {
    private func manager(runner: ScriptedRunner, cache: URL, defaultTeam: String? = nil) -> AgentManager {
        AgentManager(
            runner: runner, launcher: ProcessRunner(),
            xcode: XcodeEnvironment(developerDir: "/Xcode.app/Contents/Developer", version: "27.1", build: nil),
            paths: AgentPaths(source: cache, cache: cache), defaultTeam: defaultTeam, lockState: { _ in false })
    }

    private func xcodeTeams(_ teams: [(String, String, Bool)]) -> String {
        let entries = teams.map { ["teamID": $0.0, "teamName": $0.1, "isFreeProvisioningTeam": $0.2] as [String: Any] }
        let data = try! PropertyListSerialization.data(
            fromPropertyList: ["IDEProvisioningTeamByIdentifier": ["account": entries]], format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func severalTeamsNeedAChoiceThatIsRemembered() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("agent-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let runner = ScriptedRunner()
        runner.on("export com.apple.dt.Xcode", stdout: xcodeTeams([("47A38L5NX6", "BZZR, Inc.", false), ("VYL36DLB34", "Alexey Rott (Personal Team)", true)]))
        let agent = manager(runner: runner, cache: cache)
        await #expect(throws: ISimError.self) { try await agent.resolveTeam(nil) }
        do {
            _ = try await agent.resolveTeam(nil)
        } catch {
            #expect("\(error)".contains("47A38L5NX6 (BZZR, Inc.), VYL36DLB34 (Alexey Rott (Personal Team); its profiles last 7 days)"))
        }
        #expect(try await agent.resolveTeam("AB12CD34EF") == "AB12CD34EF")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("VYL36DLB34\n".utf8).write(to: cache.appendingPathComponent("team"))
        #expect(try await agent.resolveTeam(nil) == "VYL36DLB34")
        #expect(try await manager(runner: runner, cache: cache, defaultTeam: "47A38L5NX6").resolveTeam(nil) == "47A38L5NX6")
    }

    @Test func theOnlyTeamIsTaken() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("agent-cache-\(UUID().uuidString)")
        let runner = ScriptedRunner()
        runner.on("export com.apple.dt.Xcode", stdout: xcodeTeams([("VYL36DLB34", "Alexey Rott (Personal Team)", true)]))
        #expect(try await manager(runner: runner, cache: cache).resolveTeam(nil) == "VYL36DLB34")
    }
}
