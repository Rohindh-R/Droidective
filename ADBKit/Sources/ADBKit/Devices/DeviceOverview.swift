import Foundation

/// Hardware/usage overview for the device-info panel: memory, storage,
/// battery (incl. health and cycle count where the ROM reports it), CPU
/// architecture, and app counts.
public struct DeviceOverview: Sendable, Equatable {
    public var ramTotalKb: Int?
    public var ramAvailableKb: Int?
    public var storageTotalKb: Int?
    public var storageUsedKb: Int?
    public var storageAvailableKb: Int?
    public var batteryLevel: Int?
    public var batteryHealth: String?
    public var batteryCycleCount: Int?
    public var cpuAbi: String?
    public var userAppCount: Int?
    public var systemAppCount: Int?

    public var ramUsedKb: Int? {
        guard let ramTotalKb, let ramAvailableKb else { return nil }
        return ramTotalKb - ramAvailableKb
    }

    // MARK: - Parsers (pure)

    /// `/proc/meminfo` → (totalKb, availableKb).
    public static func parseMeminfo(_ output: String) -> (total: Int?, available: Int?) {
        func value(_ key: String) -> Int? {
            output.range(of: "\(key):\\s*(\\d+)", options: .regularExpression)
                .map { Int(String(output[$0]).filter(\.isNumber)) } ?? nil
        }
        return (value("MemTotal"), value("MemAvailable"))
    }

    /// `df -k /data` → (totalKb, usedKb, availableKb).
    public static func parseDf(_ output: String) -> (total: Int?, used: Int?, available: Int?) {
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else { return (nil, nil, nil) }
        // Split on any whitespace (incl. a trailing CR on CRLF output) so the
        // last numeric column parses cleanly.
        let fields = lines[1].split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4 else { return (nil, nil, nil) }
        return (Int(fields[1]), Int(fields[2]), Int(fields[3]))
    }

    /// `dumpsys battery` → (level, health label, cycle count).
    public static func parseBattery(_ output: String) -> (level: Int?, health: String?, cycles: Int?) {
        let level = output.firstMatch(of: /level:\s*(\d+)/).flatMap { Int($0.1) }
        let healthCode = output.firstMatch(of: /health:\s*(\d+)/).flatMap { Int($0.1) }
        let health: String? = healthCode.map {
            switch $0 {
            case 2: return "Good"
            case 3: return "Overheat"
            case 4: return "Dead"
            case 5: return "Over voltage"
            case 6: return "Failure"
            case 7: return "Cold"
            default: return "Unknown"
            }
        }
        let cycles = output.firstMatch(of: /(?i)cycle count:\s*(\d+)/).flatMap { Int($0.1) }
        return (level, health, cycles)
    }

    static func countPackages(_ output: String) -> Int {
        output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("package:") }.count
    }

    // MARK: - Fetch

    public static func fetch(client: AdbClient, serial: String) async -> DeviceOverview {
        async let meminfoResult = try? client.run(on: serial, ["shell", "cat", "/proc/meminfo"])
        async let dfResult = try? client.run(on: serial, ["shell", "df", "-k", "/data"])
        async let batteryResult = try? client.run(on: serial, ["shell", "dumpsys", "battery"])
        async let abiResult = try? client.run(on: serial, ["shell", "getprop", "ro.product.cpu.abi"])
        async let userAppsResult = try? client.run(on: serial, ["shell", "pm", "list", "packages", "-3"])
        async let systemAppsResult = try? client.run(on: serial, ["shell", "pm", "list", "packages", "-s"])

        var overview = DeviceOverview()
        if let meminfo = await meminfoResult {
            (overview.ramTotalKb, overview.ramAvailableKb) = parseMeminfo(meminfo.stdout)
        }
        if let df = await dfResult {
            (overview.storageTotalKb, overview.storageUsedKb, overview.storageAvailableKb) = parseDf(df.stdout)
        }
        if let battery = await batteryResult {
            (overview.batteryLevel, overview.batteryHealth, overview.batteryCycleCount) = parseBattery(battery.stdout)
        }
        if let abi = await abiResult {
            let trimmed = abi.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            overview.cpuAbi = trimmed.isEmpty ? nil : trimmed
        }
        if let userApps = await userAppsResult {
            overview.userAppCount = countPackages(userApps.stdout)
        }
        if let systemApps = await systemAppsResult {
            overview.systemAppCount = countPackages(systemApps.stdout)
        }
        return overview
    }
}
