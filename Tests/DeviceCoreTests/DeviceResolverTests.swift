import DeviceCore
import Testing

private func sim(_ name: String, _ udid: String, _ state: DeviceState = .shutdown, available: Bool = true) -> Device {
    Device(udid: udid, name: name, kind: .simulator, state: state, osVersion: "27.0", isAvailable: available)
}

private func phone(_ name: String, _ udid: String, _ state: DeviceState = .connected) -> Device {
    Device(udid: udid, name: name, kind: .physical, state: state, osVersion: "27.0.1")
}

struct DeviceResolverTests {
    let booted = sim("iPhone 16 Pro", "AAAA-0001", .booted)
    let shutdown = sim("iPhone 17", "AAAA-0002")
    let duoOld = sim("iPhone Duo", "AAAA-0003")
    let duoNew = sim("iPhone Duo", "AAAA-0004")
    let iphone = phone("Test iPhone", "00008110-0001")

    var all: [Device] { [booted, shutdown, duoOld, duoNew, iphone] }

    @Test func matchesUDIDCaseInsensitively() throws {
        #expect(try DeviceResolver.resolve(query: "aaaa-0002", activeUDID: nil, devices: all) == shutdown)
    }

    @Test func matchesName() throws {
        #expect(try DeviceResolver.resolve(query: "test iphone", activeUDID: nil, devices: all) == iphone)
    }

    @Test func explicitQueryWinsOverActiveDevice() throws {
        #expect(try DeviceResolver.resolve(query: "iPhone 17", activeUDID: booted.udid, devices: all) == shutdown)
    }

    @Test func ambiguousNamePrefersTheOnlyRunningDevice() throws {
        let running = sim("iPhone Duo", "AAAA-0004", .booted)
        #expect(try DeviceResolver.resolve(query: "iPhone Duo", activeUDID: nil, devices: [duoOld, running]) == running)
    }

    @Test func ambiguousNameWithoutRunningDeviceFails() {
        #expect(throws: ISimError.ambiguousDevice(query: "iPhone Duo", matches: [duoOld, duoNew])) {
            try DeviceResolver.resolve(query: "iPhone Duo", activeUDID: nil, devices: all)
        }
    }

    @Test func unknownDeviceListsAvailableOnes() {
        let unavailable = sim("Old", "AAAA-0009", available: false)
        #expect(throws: ISimError.deviceNotFound(query: "nope", available: [booted])) {
            try DeviceResolver.resolve(query: "nope", activeUDID: nil, devices: [booted, unavailable])
        }
    }

    @Test func unavailableSimulatorIsNotMatchedByName() {
        let unavailable = sim("Old", "AAAA-0009", available: false)
        #expect(throws: ISimError.self) {
            try DeviceResolver.resolve(query: "Old", activeUDID: nil, devices: [unavailable])
        }
    }

    @Test func usesActiveDevice() throws {
        #expect(try DeviceResolver.resolve(query: nil, activeUDID: shutdown.udid, devices: all) == shutdown)
    }

    @Test func activeDeviceThatDisappearedFails() {
        #expect(throws: ISimError.activeDeviceGone(udid: "GONE")) {
            try DeviceResolver.resolve(query: nil, activeUDID: "GONE", devices: all)
        }
    }

    @Test func picksTheOnlyRunningDevice() throws {
        #expect(try DeviceResolver.resolve(query: "  ", activeUDID: nil, devices: [booted, shutdown]) == booted)
        #expect(try DeviceResolver.resolve(query: nil, activeUDID: nil, devices: [shutdown, iphone]) == iphone)
    }

    @Test func severalRunningDevicesNeedAChoice() {
        #expect(throws: ISimError.noDeviceSelected(running: [booted, iphone])) {
            try DeviceResolver.resolve(query: nil, activeUDID: nil, devices: all)
        }
    }

    @Test func nothingRunningSuggestsBooting() throws {
        let error = #expect(throws: ISimError.self) {
            try DeviceResolver.resolve(query: nil, activeUDID: nil, devices: [shutdown])
        }
        #expect(error?.description.contains("boot_device") == true)
    }

    @Test func notReadyMessagesSayWhatToDo() {
        #expect(ISimError.deviceNotReady(shutdown).description.contains("Call boot_device first"))
        #expect(ISimError.deviceNotReady(phone("P", "1", .disconnected)).description.contains("not connected"))
    }
}
