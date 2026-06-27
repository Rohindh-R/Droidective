import Foundation

/// Lightweight per-device enrichment for the device picker: Android version
/// and battery level. Fetched lazily, not part of the 2s polling loop.
public struct DeviceDetails: Sendable, Equatable {
    public let androidVersion: String?
    public let batteryLevel: Int?

    public static func fetch(client: AdbClient, serial: String) async -> DeviceDetails {
        async let versionResult = try? client.run(on: serial, ["shell", "getprop", "ro.build.version.release"])
        async let batteryResult = try? client.run(on: serial, ["shell", "dumpsys", "battery"])

        let version = (await versionResult)?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Reuse DeviceOverview's parser so battery-level parsing lives in one
        // place (and inherits its line-anchored, decoy-proof matching).
        let battery = (await batteryResult).flatMap { DeviceOverview.parseBattery($0.stdout).level }

        return DeviceDetails(
            androidVersion: (version?.isEmpty == false) ? version : nil,
            batteryLevel: battery
        )
    }
}
