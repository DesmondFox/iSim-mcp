import Foundation

/// Picks the device a tool works with:
/// explicit `device` (UDID or name) → session's active device → the only booted simulator / connected iPhone.
public enum DeviceResolver {
    public static func resolve(query: String?, activeUDID: String?, devices: [Device]) throws(ISimError) -> Device {
        if let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            return try match(query, in: devices)
        }
        if let activeUDID {
            guard let device = devices.first(where: { $0.udid.caseInsensitiveCompare(activeUDID) == .orderedSame }) else {
                throw .activeDeviceGone(udid: activeUDID)
            }
            return device
        }
        let running = devices.filter(\.state.isReady)
        guard running.count == 1 else { throw .noDeviceSelected(running: running) }
        return running[0]
    }

    public static func match(_ query: String, in devices: [Device]) throws(ISimError) -> Device {
        if let device = devices.first(where: { $0.udid.caseInsensitiveCompare(query) == .orderedSame }) {
            return device
        }
        let named = devices.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame && $0.isAvailable }
        switch named.count {
        case 0:
            throw .deviceNotFound(query: query, available: devices.filter(\.isAvailable))
        case 1:
            return named[0]
        default:
            // Same-named simulators on different runtimes are common; the running one is the obvious pick.
            let running = named.filter(\.state.isReady)
            if running.count == 1 { return running[0] }
            throw .ambiguousDevice(query: query, matches: named)
        }
    }
}
