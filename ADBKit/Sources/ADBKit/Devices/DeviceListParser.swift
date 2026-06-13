import Foundation

/// Parses `adb devices -l` output into `Device` values, skipping headers and
/// daemon-startup noise.
public enum DeviceListParser {
    public static func parse(_ output: String) -> [Device] {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0)) }
    }

    public static func parseLine(_ line: String) -> Device? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("List of devices") { return nil }
        if trimmed.hasPrefix("*") || trimmed.hasPrefix("adb server") { return nil }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { return nil }
        let serial = tokens[0]
        let state = tokens[1]

        var tags: [String: String] = [:]
        for token in tokens.dropFirst(2) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else { continue }
            tags[String(token[..<colon])] = String(token[token.index(after: colon)...])
        }

        let model = tags["model"]?.replacingOccurrences(of: "_", with: " ")
        // ip:port serials (tcpip mode) or Android 11+ mDNS pairing serials.
        let isWireless = serial.wholeMatch(of: /\d{1,3}(\.\d{1,3}){3}:\d+/) != nil
            || serial.contains("_adb-tls-connect")
        let label = model.map { "\($0) (\(shortSerial(serial)))" } ?? serial

        return Device(
            serial: serial,
            state: state,
            model: model,
            product: tags["product"],
            transportId: tags["transport_id"],
            label: label,
            isWireless: isWireless
        )
    }

    static func shortSerial(_ serial: String) -> String {
        let cleaned = serial.filter { $0.isLetter || $0.isNumber }
        return cleaned.count > 4 ? String(cleaned.suffix(4)) : cleaned
    }
}
