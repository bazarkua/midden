import Foundation

/// A simulator as `xcrun simctl list devices -j` describes it.
struct SimulatorDevice: Sendable, Hashable, Decodable {
    var udid: String
    var name: String
    var isAvailable: Bool
    var availabilityError: String?
    /// Filled in from the runtime the device is listed under.
    var runtime: String = ""

    private enum CodingKeys: String, CodingKey {
        case udid, name, isAvailable, availabilityError
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-2" → "iOS 17.2".
    var runtimeName: String {
        let short = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        guard let dash = short.firstIndex(of: "-") else { return short }
        return short[..<dash] + " " + short[short.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
    }
}

enum Simulators {
    static func devicesFolder(home: String) -> String {
        home + "/Library/Developer/CoreSimulator/Devices"
    }

    /// Simulators simctl marks unavailable, usually because their runtime is
    /// no longer installed. Only asks simctl when the user has simulators,
    /// so Macs without Xcode never see a developer tools prompt.
    ///
    /// Returns nil when it can't tell, which includes the App Sandbox: there
    /// simctl reported all 12 healthy simulators of a test Mac as unavailable.
    static func unavailable(home: String, sandboxed: Bool = Sandbox.isActive) -> [SimulatorDevice]? {
        guard !sandboxed else { return nil }
        guard FileManager.default.fileExists(atPath: devicesFolder(home: home)) else { return [] }
        let result = Command.run(["xcrun", "simctl", "list", "devices", "-j"], timeout: 60)
        guard result.succeeded else { return nil }
        return parse(Data(result.output.utf8))?.filter { !$0.isAvailable }
    }

    static func parse(_ json: Data) -> [SimulatorDevice]? {
        struct List: Decodable {
            var devices: [String: [SimulatorDevice]]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: json) else { return nil }
        return list.devices.flatMap { runtime, devices in
            devices.map { device in
                var device = device
                device.runtime = runtime
                return device
            }
        }.sorted { $0.udid < $1.udid }
    }
}
