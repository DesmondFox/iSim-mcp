import DeviceCore
import Foundation
@testable import LockdownBackend
import ProcessKit
import TestSupport
import Testing

/// Bytes from memory in place of a socket; what is written is kept.
final class DataStream: ByteStream {
    private var input: Data
    private(set) var written = Data()

    init(_ input: Data) {
        self.input = input
    }

    func write(_ data: Data) throws {
        written += data
    }

    func read(exactly count: Int) throws -> Data {
        guard input.count >= count else { throw LockdownError("The iPhone closed the connection.") }
        return try read(upTo: count)
    }

    func read(upTo maxLength: Int) throws -> Data {
        let chunk = input.prefix(maxLength)
        input.removeFirst(chunk.count)
        return Data(chunk)
    }
}

/// usbmuxd and lockdownd framing, pair records, and os_trace_relay's stream: fixture bytes from an iPhone 14 Plus (iOS 27.0.1).
struct LockdownTests {
    // MARK: usbmuxd

    @Test func usbmuxPacketsHaveALittleEndianHeader() throws {
        let packet = try USBMux.packet(["MessageType": "ListDevices"], tag: 7)
        let header = packet.prefix(16).withUnsafeBytes { raw in (0..<4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian } }
        #expect(header == [UInt32(packet.count), 1, 8, 7])
        let plist = try #require(PropertyListSerialization.propertyList(from: packet.dropFirst(16), format: nil) as? [String: String])
        #expect(plist["MessageType"] == "ListDevices")
        #expect(plist["ProgName"] == "isim-mcp")

        let reply = try USBMux.readPacket(from: DataStream(try USBMux.packet(["Number": 0])))
        #expect(reply["Number"] as? Int == 0)
    }

    @Test func usbmuxRejectsATruncatedReply() {
        let packet = try! USBMux.packet(["Number": 0])
        #expect(throws: LockdownError.self) { try USBMux.readPacket(from: DataStream(packet.dropLast(3))) }
    }

    @Test func picksTheDeviceByUDIDPreferringUSB() throws {
        let devices = [
            USBMux.DeviceEntry(id: 3, serial: "00008110-000244D21181401E", connection: "Network"),
            USBMux.DeviceEntry(id: 5, serial: "00008110000244D21181401E", connection: "USB"),
            USBMux.DeviceEntry(id: 9, serial: "OTHER", connection: "USB"),
        ]
        #expect(try USBMux.device(for: "00008110-000244D21181401E", in: devices).id == 5)
        #expect(try USBMux.device(for: "00008110-000244d21181401e", in: Array(devices.prefix(1))).connection == "Network")
        let error = #expect(throws: LockdownError.self) { try USBMux.device(for: "MISSING", in: devices) }
        #expect(error?.description.hasPrefix("usbmuxd does not see MISSING: connect the iPhone by USB") == true)
    }

    // MARK: Pair records and lockdownd

    @Test func pairRecordGivesAnIdentityWithoutAKeychain() throws {
        // A throwaway key and self-signed certificate, PKCS#8 like the records usbmuxd keeps.
        let record = try PairRecord(plist: try fixture("pair-record.plist"))
        #expect(record.hostID == "00000000-1111-2222-3333-444444444444")
        #expect(record.systemBUID == "55555555-6666-7777-8888-999999999999")
        #expect(record.hostPrivateKey.first == 0x30)
        let identity = try record.identity()
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
        #expect(certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } == "isim-mcp test host")
    }

    @Test func incompletePairRecordsAreRejected() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["HostID": "X"], format: .binary, options: 0)
        let error = #expect(throws: LockdownError.self) { try PairRecord(plist: data) }
        #expect(error?.description.contains("unpair the iPhone in Xcode") == true)
    }

    @Test func pkcs8UnwrapsToTheRSAKey() throws {
        // SEQUENCE { INTEGER 0, SEQUENCE {}, OCTET STRING { 01 02 03 } }
        let der = Data([0x30, 0x0A, 0x02, 0x01, 0x00, 0x30, 0x00, 0x04, 0x03, 0x01, 0x02, 0x03])
        #expect(try DER.pkcs1(fromPKCS8: der) == Data([1, 2, 3]))
        #expect(throws: LockdownError.self) { try DER.pkcs1(fromPKCS8: der.dropLast()) }
        // A long-form length: 0x81 0x80 is 128 bytes.
        var offset = 0
        let long = Data([0x04, 0x81, 0x80]) + Data(repeating: 7, count: 128)
        #expect(try DER.element(long, at: &offset, tag: 0x04) == 3..<131)
    }

    @Test func lockdownMessagesAreBigEndianLengthAndPlist() throws {
        let message = try LockdownClient.message(["Request": "QueryType"])
        #expect(message.prefix(4) == withUnsafeBytes(of: UInt32(message.count - 4).bigEndian) { Data($0) })
        let reply = try LockdownClient.readMessage(from: DataStream(message))
        #expect(reply["Request"] as? String == "QueryType")
    }

    @Test func lockdownErrorsSayWhatToDo() {
        #expect(LockdownClient.failure("PasswordProtected", request: "StartSession").description
            == "lockdownd refused StartSession: PasswordProtected. Unlock the iPhone.")
        #expect(LockdownClient.failure("InvalidHostID", request: "StartSession").description.contains("tap Trust"))
    }

    // MARK: os_trace_relay

    private func frames() throws -> (stream: DataStream, entries: [OSTraceEntry]) {
        let stream = DataStream(try fixture("os_trace_relay-activity.bin"))
        try OSTraceRelay.readReply(from: stream)
        var entries: [OSTraceEntry] = []
        while let frame = try OSTraceRelay.readFrame(from: stream, marker: 2) {
            entries.append(try OSTraceEntry(frame))
        }
        return (stream, entries)
    }

    @Test func streamFramesEndWhenTheDeviceCloses() throws {
        let (stream, entries) = try frames()
        #expect(entries.count == 5)
        #expect(try OSTraceRelay.readFrame(from: stream, marker: 2) == nil)
    }

    @Test func refusedRequestsAndForeignFramesFail() throws {
        let body = try PropertyListSerialization.data(fromPropertyList: ["Status": "RequestFailed"], format: .binary, options: 0)
        let reply = Data([1]) + withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) } + body
        let refused = #expect(throws: LockdownError.self) { try OSTraceRelay.readReply(from: DataStream(reply)) }
        #expect(refused?.description == "os_trace_relay refused the request: RequestFailed.")
        #expect(throws: LockdownError.self) { try OSTraceRelay.readFrame(from: DataStream(Data([3, 0, 0, 0, 0])), marker: 2) }
    }

    @Test func entriesCarryProcessSubsystemAndLevel() throws {
        let entries = try frames().entries
        let debug = entries[0]
        #expect(debug.kind == .log)
        #expect(debug.level == .debug)
        #expect(debug.pid == 8717)
        #expect(debug.threadID == 0x4a4b81)
        #expect(abs(debug.date.timeIntervalSince1970 - 1_793_025_214.502913) < 0.000_01)
        #expect(debug.process == "backboardd")
        #expect(debug.processPath == "/usr/libexec/backboardd")
        #expect(debug.sender == "CoreBrightness")
        #expect(debug.subsystem == "com.apple.CoreBrightness.Display.1")
        #expect(debug.category == "default")
        #expect(debug.message.hasPrefix("now=814718014.502755 delta=9.586168"))

        #expect(entries[1].level == .info)
        #expect(entries[1].subsystem == nil)
        #expect(entries[2].level == .error)
        #expect(entries[2].process == "SpringBoard")
        #expect(entries[2].message == "error: unknown notification type (<private>)")
        #expect(entries[3].level == .default)

        // Activities use the subsystem fields for something else.
        let activity = entries[4]
        #expect(activity.kind == .activity)
        #expect(activity.subsystem == nil)
        #expect(activity.message == "tcc_send_request_authorization() IPC")
    }

    @Test func linesLookLikeLogsCompactStyle() throws {
        let entries = try frames().entries
        // After the local-time timestamp, "2026-10-26 16:33:34.502 ".
        let lines = entries.map { String($0.compactLine.dropFirst(24)) }
        #expect(lines[0].hasPrefix("Db backboardd[8717:4a4b81] [com.apple.CoreBrightness.Display.1:default] now=814718014.502755"))
        #expect(lines[1].hasPrefix("I  backboardd[8717:4a4b81] (libEDR) libEDR - EDRServerSetDisplayBrightnessForDisplay"))
        #expect(lines[2] == "E  SpringBoard[8681:4a4aee] [com.apple.CoreBrightness.Client.Adaptation:default] error: unknown notification type (<private>)")
        #expect(lines[3].hasPrefix("Df SpringBoard[8681:4a4aee] [com.apple.CoreBrightness.Client.Adaptation:default] no callback"))
        #expect(lines[4] == "A  UserEventAgent[8677:4a4b46] (TCC) tcc_send_request_authorization() IPC")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        #expect(entries[0].compactLine.hasPrefix(formatter.string(from: entries[0].date) + " Db "))
    }

    @Test func levelsFollowLogStream() throws {
        let entries = try frames().entries
        #expect(entries.filter { $0.passes(.default) }.map(\.level) == [.error, .default])
        #expect(entries.filter { $0.passes(.info) }.count == 4)
        #expect(entries.allSatisfy { $0.passes(.debug) })
    }

    @Test func filterRunsOnTheMac() throws {
        let entries = try frames().entries
        func matching(_ filter: LogFilter) throws -> [Int] {
            let matcher = try EntryMatcher(filter)
            return entries.indices.filter { matcher.matches(entries[$0]) }
        }
        // An app: its process, or its bundle id as subsystem.
        #expect(try matching(LogFilter(app: ("com.apple.CoreBrightness.Display.1", "SpringBoard"))) == [0, 2, 3])
        #expect(try matching(LogFilter(process: "backboardd", level: .info)) == [1])
        #expect(try matching(LogFilter(predicate: #"composedMessage CONTAINS[c] "NOTIFICATION" AND logType == "error""#)) == [2])
        #expect(try matching(LogFilter(predicate: #"messageType == "default" OR sender == "TCC""#)) == [3, 4])
        #expect(try matching(LogFilter(predicate: "processIdentifier == 8677 AND type == \"activityCreateEvent\"")) == [4])
        // Comparing a number with CONTAINS raises in NSPredicate: no match, no crash.
        #expect(try matching(LogFilter(predicate: #"processIdentifier CONTAINS "8""#)).isEmpty)

        let error = #expect(throws: LockdownError.self) { try EntryMatcher(LogFilter(predicate: "process ==")) }
        #expect(error?.description.hasPrefix("The predicate does not parse:") == true)
    }

    // MARK: Backend

    @Test func streamRunsTheHelperAndWaitsForIt() {
        let backend = LockdownBackend(runner: ScriptedRunner(), helper: "/bin/isim-mcp")
        let command = backend.logStreamCommand(
            udid: "PHONE-1", filter: LogFilter(app: ("dev.x", "XApp"), predicate: #"logType == "error""#, level: .info))
        #expect(command.executable == "/bin/isim-mcp")
        #expect(command.arguments == [
            "device-log", "--udid", "PHONE-1", "--bundle-id", "dev.x", "--executable", "XApp", "--predicate", #"logType == "error""#, "--level", "info",
        ])
        #expect(command.readyMarker == DeviceLog.readyMarker)
        #expect(command.noise == [NSRegularExpression.escapedPattern(for: DeviceLog.readyMarker)])
    }

    @Test func queryDownloadsTheArchiveAndAsksLogShow() async throws {
        let runner = ScriptedRunner()
        runner.on("device-log --udid PHONE-1 --archive")
        runner.on("show --archive", stdout: """
            Filtering the log data using "process == "X""
            Timestamp               Ty Process[PID:TID]
            2026-10-26 16:48:50.629 I  X[14510:4a6c96] [dev.x:lab] lab opened
            """)
        let lines = try await LockdownBackend(runner: runner, helper: "/bin/isim-mcp").queryLogs(udid: "PHONE-1", filter: LogFilter(process: "X"), last: .seconds(90))
        #expect(lines == ["2026-10-26 16:48:50.629 I  X[14510:4a6c96] [dev.x:lab] lab opened"])
        let download = try #require(runner.calls.first)
        #expect(download.executable == "/bin/isim-mcp")
        #expect(download.arguments.suffix(2) == ["--last", "90"])
        let archive = download.arguments[download.arguments.firstIndex(of: "--archive")! + 1]
        #expect(runner.calls.last?.executable == "/usr/bin/log")
        #expect(runner.calls.last?.arguments == [
            "show", "--archive", archive, "--style", "compact", "--last", "90s", "--info", "--debug", "--predicate", #"process == "X""#,
        ])
    }

    @Test func queryReportsTheHelpersError() async throws {
        let runner = ScriptedRunner()
        runner.on("device-log", exitCode: 1, stderr: "isim-mcp: usbmuxd does not see PHONE-1: connect the iPhone by USB.\n")
        let error = await #expect(throws: ISimError.self) {
            try await LockdownBackend(runner: runner, helper: "/bin/isim-mcp").queryLogs(udid: "PHONE-1", filter: LogFilter(process: "X"), last: .seconds(60))
        }
        #expect(error?.description == "`isim-mcp device-log --archive` failed: isim-mcp: usbmuxd does not see PHONE-1: connect the iPhone by USB.")
        #expect(runner.calls.count == 1)
    }
}
