import DeviceCore
import Foundation
import Testing

struct LogFilterTests {
    @Test func combinesConditionsWithAnd() {
        let filter = LogFilter(app: ("dev.isimmcp.testapp", "ISimTestApp"), subsystem: "net", predicate: #"eventMessage CONTAINS "x""#)
        #expect(filter.predicateString == #"(process == "ISimTestApp" OR subsystem == "dev.isimmcp.testapp") AND subsystem == "net" AND (eventMessage CONTAINS "x")"#)
    }

    @Test func quotesNames() {
        #expect(LogFilter(process: #"My "App""#).predicateString == #"process == "My \"App\"""#)
        #expect(LogFilter().predicateString == nil)
        #expect(LogFilter().isEmpty)
    }
}

struct CrashReportEntryTests {
    @Test func takesTheProcessFromTheFileName() {
        #expect(CrashReportEntry.processName(fromFileName: "ISimTestApp-2026-10-23-123148.ips") == "ISimTestApp")
        #expect(CrashReportEntry.processName(fromFileName: "ISimAgentRunner-Runner-2026-10-22-191632.ips") == "ISimAgentRunner-Runner")
        #expect(CrashReportEntry.processName(fromFileName: "siriactionsd-2026-10-22-174334.0002.ips") == "siriactionsd")
        #expect(CrashReportEntry.processName(fromFileName: "notes.txt") == nil)
    }

    @Test func tellsCrashesFromOtherReports() {
        #expect(CrashReportEntry.kind(bugType: "309", name: "x.ips") == .crash)
        #expect(CrashReportEntry.kind(bugType: "298", name: "x.ips") == .jetsam)
        #expect(CrashReportEntry.kind(bugType: nil, name: "JetsamEvent-2026-10-22-200453.ips") == .jetsam)
        #expect(CrashReportEntry.kind(bugType: nil, name: "logd.diskwrites_resource-2026-10-20-175223.ips") == .resource)
        #expect(CrashReportEntry.kind(bugType: nil, name: "stacks-2026-10-23-122528.ips") == .stackshot)
        #expect(CrashReportEntry.kind(bugType: nil, name: "ISimTestApp-2026-10-23-123148.ips") == .crash)
    }
}

struct CrashReportTests {
    @Test func readsAnObjectiveCException() throws {
        let header = #"{"app_name":"Demo","bundleID":"com.example.demo","bug_type":"309","os_version":"iPhone OS 27.0 (24A1)"}"#
        let body: [String: Any] = [
            "procName": "Demo",
            "bundleInfo": ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "7", "CFBundleIdentifier": "com.example.demo"],
            "exception": ["type": "EXC_CRASH", "signal": "SIGABRT", "codes": "0x0, 0x0"],
            "termination": ["namespace": "SIGNAL", "code": 6, "indicator": "Abort trap: 6"],
            "asi": ["CoreFoundation": ["*** Terminating app due to uncaught exception 'NSRangeException'"]],
            "faultingThread": 1,
            "threads": [
                ["frames": []],
                ["queue": "com.apple.main-thread", "frames": [["imageIndex": 0, "imageOffset": 4096]]],
            ],
            "lastExceptionBacktrace": [["imageIndex": 1, "symbol": "__exceptionPreprocess", "symbolLocation": 164]],
            "usedImages": [["name": "Demo"], ["path": "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"]],
        ]
        let data = Data(header.utf8) + Data("\n".utf8) + (try JSONSerialization.data(withJSONObject: body))
        let report = try CrashReport.parse(data)
        #expect(report.process == "Demo")
        #expect(report.version == "1.2 (7)")
        #expect(report.exception == "EXC_CRASH (SIGABRT), codes 0x0, 0x0")
        #expect(report.termination == "SIGNAL 6 Abort trap: 6")
        #expect(report.applicationSpecific == ["*** Terminating app due to uncaught exception 'NSRangeException'"])
        #expect(report.crashedThread == 1)
        #expect(report.crashedThreadName == "com.apple.main-thread")
        #expect(report.frames == [CrashReport.Frame(image: "Demo", symbol: nil, offset: 4096)])
        #expect(report.exceptionBacktrace == [CrashReport.Frame(image: "CoreFoundation", symbol: "__exceptionPreprocess", offset: 164)])
    }

    @Test func aReportWithoutAnExceptionIsNotACrash() throws {
        let report = try CrashReport.parse(Data(#"{"bug_type":"298","name":"JetsamEvent"}"#.utf8) + Data("\n{\"memoryStatus\": {}}".utf8))
        #expect(!report.isCrash)
        #expect(report.bugType == "298")
    }

    @Test func rejectsWhatIsNotAReport() {
        #expect(throws: ISimError.self) { try CrashReport.parse(Data("hello".utf8)) }
    }
}

struct AppDataTests {
    @Test func normalizesContainerPaths() throws {
        #expect(try ContainerPath.normalize("/Documents/./a.txt") == "Documents/a.txt")
        #expect(try ContainerPath.normalize("") == "")
        #expect(throws: ISimError.self) { try ContainerPath.normalize("Documents/../../etc") }
    }

    @Test func writesPropertyListElements() throws {
        #expect(try PropertyList.xmlElement(NSNumber(value: true)) == "<true/>")
        #expect(try PropertyList.xmlElement(NSNumber(value: 3)) == "<integer>3</integer>")
        #expect(try PropertyList.xmlElement(NSNumber(value: 1.5)) == "<real>1.5</real>")
        #expect(try PropertyList.xmlElement("a < b & c") == "<string>a &lt; b &amp; c</string>")
        #expect(try PropertyList.xmlElement(["beta": NSNumber(value: false), "list": ["x"]] as [String: Any])
            == "<dict><key>beta</key><false/><key>list</key><array><string>x</string></array></dict>")
        #expect(throws: ISimError.self) { try PropertyList.xmlElement(NSNull()) }
    }

    @Test func showsPropertyListsAsJSON() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(PropertyList.json(["when": date, "n": 1] as [String: Any]) == """
            {
              "n" : 1,
              "when" : "1970-01-01T00:00:00Z"
            }
            """)
    }
}
