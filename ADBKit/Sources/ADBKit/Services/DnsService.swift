import Foundation

/// The device's Private DNS (DNS-over-TLS) setting.
public struct DnsStatus: Sendable, Equatable {
    public enum Mode: String, Sendable {
        case off
        case automatic
        case hostname
    }

    public let mode: Mode
    public let hostname: String?

    public init(mode: Mode, hostname: String?) {
        self.mode = mode
        self.hostname = hostname
    }
}

/// Read and set Private DNS via the `private_dns_mode` / `private_dns_specifier`
/// global settings (Android 9+). No root required.
public struct DnsService: Sendable {
    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    public func current(serial: String) async -> DnsStatus {
        let mode = (try? await client.run(on: serial, ["shell", "settings", "get", "global", "private_dns_mode"]))?.stdout ?? ""
        let specifier = (try? await client.run(on: serial, ["shell", "settings", "get", "global", "private_dns_specifier"]))?.stdout ?? ""
        return Self.parse(mode: mode, specifier: specifier)
    }

    public func setOff(serial: String) async throws(AdbError) -> AdbResult {
        try await client.run(on: serial, ["shell", "settings", "put", "global", "private_dns_mode", "off"])
    }

    public func setAutomatic(serial: String) async throws(AdbError) -> AdbResult {
        try await client.run(on: serial, ["shell", "settings", "put", "global", "private_dns_mode", "opportunistic"])
    }

    public func setHostname(serial: String, _ hostname: String) async throws(AdbError) -> AdbResult {
        _ = try await client.run(on: serial, ["shell", "settings", "put", "global", "private_dns_specifier", shellQuote(hostname)])
        return try await client.run(on: serial, ["shell", "settings", "put", "global", "private_dns_mode", "hostname"])
    }

    static func parse(mode: String, specifier: String) -> DnsStatus {
        let trimmedMode = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = (host.isEmpty || host == "null") ? nil : host
        switch trimmedMode {
        case "off":
            return DnsStatus(mode: .off, hostname: hostname)
        case "hostname":
            return DnsStatus(mode: .hostname, hostname: hostname)
        default:
            // "opportunistic", "null", or unset — Android's default is automatic.
            return DnsStatus(mode: .automatic, hostname: hostname)
        }
    }
}
