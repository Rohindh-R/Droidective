import Foundation

/// getprop access for the device-info panel and feature runners.
public enum DeviceProps {
    /// Parse a full `getprop` dump (`[key]: [value]` lines) into a map.
    public static func parse(_ output: String) -> [String: String] {
        var props: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = trimmed.wholeMatch(of: /\[(.+?)\]:\s*\[(.*?)\]/) else { continue }
            props[String(match.1)] = String(match.2)
        }
        return props
    }

    public static func all(client: AdbClient, serial: String) async throws(AdbError) -> [String: String] {
        let result = try await client.run(on: serial, ["shell", "getprop"])
        return parse(result.stdout)
    }

    public static func get(client: AdbClient, serial: String, _ prop: String) async throws(AdbError) -> String {
        let result = try await client.run(on: serial, ["shell", "getprop", prop])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
