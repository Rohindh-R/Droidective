import Foundation

/// Current Wi-Fi connection, parsed from `cmd wifi status` (Android 11+) with a
/// `dumpsys wifi` fallback.
public struct WifiStatus: Sendable, Equatable {
    public let enabled: Bool
    public let connected: Bool
    public let ssid: String?
    public let ipAddress: String?
    public let linkSpeed: String?
    public let frequency: String?
    public let signal: String?

    public init(
        enabled: Bool, connected: Bool, ssid: String?, ipAddress: String?,
        linkSpeed: String?, frequency: String?, signal: String?
    ) {
        self.enabled = enabled
        self.connected = connected
        self.ssid = ssid
        self.ipAddress = ipAddress
        self.linkSpeed = linkSpeed
        self.frequency = frequency
        self.signal = signal
    }
}

/// A saved Wi-Fi network. `password` is filled only on a rooted device.
public struct WifiNetwork: Sendable, Equatable, Identifiable {
    public let networkId: Int?
    public let ssid: String
    public let security: String?
    public var password: String?

    public var id: String { networkId.map(String.init) ?? ssid }

    public init(networkId: Int?, ssid: String, security: String?, password: String? = nil) {
        self.networkId = networkId
        self.ssid = ssid
        self.security = security
        self.password = password
    }
}

/// SSID + password read from the on-device Wi-Fi config store (root only).
public struct WifiCredential: Sendable, Equatable {
    public let ssid: String
    public let password: String?
    public let security: String?

    public init(ssid: String, password: String?, security: String?) {
        self.ssid = ssid
        self.password = password
        self.security = security
    }
}

/// Inspect and control Wi-Fi over adb: read the current connection, toggle the
/// radio, list saved networks, connect to one, and — on a rooted device — read
/// saved passwords from WifiConfigStore.xml.
public struct WifiService: Sendable {
    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    /// Locations of the Wi-Fi config store across Android versions.
    static let configStorePaths = [
        "/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml",
        "/data/misc/wifi/WifiConfigStore.xml",
    ]

    public func status(serial: String) async -> WifiStatus {
        let cmdStatus = (try? await client.run(on: serial, ["shell", "cmd", "wifi", "status"]))?.stdout ?? ""
        let dumpsys: String
        if cmdStatus.lowercased().contains("wifi") || cmdStatus.contains("SSID") {
            dumpsys = ""
        } else {
            dumpsys = (try? await client.run(
                on: serial, ["shell", "dumpsys", "wifi"], maxOutputBytes: 4 * 1024 * 1024
            ))?.stdout ?? ""
        }
        let ipAddr = (try? await client.run(on: serial, ["shell", "ip", "-f", "inet", "addr", "show", "wlan0"]))?.stdout ?? ""
        return Self.parseStatus(cmdStatus: cmdStatus, dumpsys: dumpsys, ipAddr: ipAddr)
    }

    public func setEnabled(serial: String, _ on: Bool) async throws(AdbError) -> AdbResult {
        try await client.run(on: serial, ["shell", "svc", "wifi", on ? "enable" : "disable"])
    }

    public func savedNetworks(serial: String) async -> [WifiNetwork] {
        let output = (try? await client.run(on: serial, ["shell", "cmd", "wifi", "list-networks"]))?.stdout ?? ""
        return Self.parseSavedNetworks(output)
    }

    /// Connect to a network via `cmd wifi connect-network` (Android 11+; the
    /// shell needs network-settings permission, so it can fail on locked-down
    /// ROMs). `security` is open / owe / wpa2 / wpa3.
    public func connect(
        serial: String, ssid: String, security: String, password: String
    ) async throws(AdbError) -> AdbResult {
        var args = ["shell", "cmd", "wifi", "connect-network", shellQuote(ssid), security]
        if !password.isEmpty {
            args.append(shellQuote(password))
        }
        return try await client.run(on: serial, args, timeout: .seconds(20))
    }

    /// Read saved Wi-Fi credentials from the config store as root. Returns an
    /// empty array when su is unavailable or the store can't be read.
    public func savedPasswords(serial: String) async -> [WifiCredential] {
        for path in Self.configStorePaths {
            let output = (try? await client.run(
                on: serial, ["shell", "su", "-c", shellQuote("cat \(path)")]
            ))?.stdout ?? ""
            guard output.contains("<") else { continue }
            let creds = Self.parseConfigStore(output)
            if !creds.isEmpty { return creds }
        }
        return []
    }

    // MARK: - Parsing

    static func parseStatus(cmdStatus: String, dumpsys: String, ipAddr: String) -> WifiStatus {
        let text = cmdStatus.isEmpty ? dumpsys : cmdStatus
        let lower = text.lowercased()

        var ssid: String?
        if let match = text.firstMatch(of: /SSID:\s*"?([^",\n]+)"?/) {
            let value = String(match.1).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value != "<unknown ssid>", value.lowercased() != "<none>" {
                ssid = value
            }
        }
        let connected = ssid != nil

        let enabled: Bool
        if lower.contains("wifi is disabled") || lower.contains("wi-fi is disabled") {
            enabled = false
        } else if lower.contains("enabled") {
            enabled = true
        } else {
            enabled = connected
        }

        let linkSpeed = text.firstMatch(of: /Link speed:\s*(\d+)\s*Mbps/).map { "\($0.1) Mbps" }
        let frequency = text.firstMatch(of: /Frequency:\s*(\d+)\s*MHz/).map { "\($0.1) MHz" }
        let signal = text.firstMatch(of: /RSSI:\s*(-?\d+)/).map { "\($0.1) dBm" }
        let ip = ipAddr.firstMatch(of: /inet\s+(\d+\.\d+\.\d+\.\d+)/).map { String($0.1) }

        return WifiStatus(
            enabled: enabled, connected: connected, ssid: ssid, ipAddress: ip,
            linkSpeed: linkSpeed, frequency: frequency, signal: signal
        )
    }

    static func parseSavedNetworks(_ text: String) -> [WifiNetwork] {
        var networks: [WifiNetwork] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = line.wholeMatch(of: /\s*(\d+)\s{2,}(.+?)\s{2,}(\S+)\s*/) else { continue }
            networks.append(WifiNetwork(
                networkId: Int(match.1),
                ssid: String(match.2).trimmingCharacters(in: .whitespaces),
                security: String(match.3)
            ))
        }
        return networks
    }

    static func parseConfigStore(_ xml: String) -> [WifiCredential] {
        var creds: [WifiCredential] = []
        for block in xml.components(separatedBy: "<Network>") {
            guard let ssidMatch = block.firstMatch(of: /<string name="SSID">(.*?)<\/string>/) else { continue }
            let ssid = decodeConfigString(String(ssidMatch.1))
            guard !ssid.isEmpty else { continue }
            let pskMatch = block.firstMatch(of: /<string name="PreSharedKey">(.*?)<\/string>/)
            let password = pskMatch.map { decodeConfigString(String($0.1)) }
            creds.append(WifiCredential(ssid: ssid, password: password, security: password == nil ? "open" : "PSK"))
        }
        return creds
    }

    /// Decode an XML config-store string: unescape entities and strip the
    /// surrounding quotes the store wraps SSIDs and ASCII passwords in.
    static func decodeConfigString(_ raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
