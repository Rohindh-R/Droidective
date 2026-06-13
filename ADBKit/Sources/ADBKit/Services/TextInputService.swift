import Foundation

/// Robust `adb shell input text`.
///
/// `input text` can't take raw spaces and doesn't support Unicode. For ASCII
/// we escape shell metacharacters and encode spaces as `%s` (which `input
/// text` renders as a space). For Unicode we route through the ADBKeyboard
/// IME if it's installed, base64-encoding the payload to dodge shell quoting.
public struct TextInputService: Sendable {
    static let adbKeyboardIME = "com.android.adbkeyboard/.AdbIME"
    static let specialCharacters = Set("\"'`\\()<>|;&*~^$#[]{}?!")

    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    public static func escapeForInput(_ text: String) -> String {
        var escaped = ""
        for char in text {
            if char == " " {
                escaped += "%s"
            } else if specialCharacters.contains(char) {
                escaped += "\\\(char)"
            } else {
                escaped.append(char)
            }
        }
        return escaped
    }

    static func truncate(_ text: String, max: Int = 40) -> String {
        text.count > max ? "\(text.prefix(max))…" : text
    }

    public func send(serial: String, text: String) async throws(AdbError) -> FeatureResult {
        if text.isEmpty {
            return FeatureResult(ok: false, message: "Nothing to send")
        }

        // `input text` has no escape for a literal % (%s means space), so
        // %-containing text goes through the ADBKeyboard path like Unicode.
        let needsIME = text.contains { !$0.isASCII } || text.contains("%")
        if !needsIME {
            let result = try await client.run(
                on: serial, ["shell", "input", "text", Self.escapeForInput(text)]
            )
            return result.succeeded
                ? FeatureResult(ok: true, message: "Sent “\(Self.truncate(text))”")
                : FeatureResult(ok: false, message: friendlyAdbError(result, fallback: "Failed to send text"))
        }

        let imeList = try await client.run(on: serial, ["shell", "ime", "list", "-a", "-s"])
        guard imeList.stdout.contains(Self.adbKeyboardIME) else {
            return FeatureResult(
                ok: false,
                message: "This text needs the ADBKeyboard app on the device (Unicode and % can't go through `input text`).",
                needsAdbKeyboard: true
            )
        }

        let previous = try await client.run(
            on: serial, ["shell", "settings", "get", "secure", "default_input_method"]
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await client.run(on: serial, ["shell", "ime", "set", Self.adbKeyboardIME])
        let base64 = Data(text.utf8).base64EncodedString()
        let result = try await client.run(
            on: serial, ["shell", "am", "broadcast", "-a", "ADB_INPUT_B64", "--es", "msg", base64]
        )
        if !previous.isEmpty && previous != "null" {
            _ = try await client.run(on: serial, ["shell", "ime", "set", previous])
        }
        return result.succeeded
            ? FeatureResult(ok: true, message: "Sent “\(Self.truncate(text))” via ADBKeyboard")
            : FeatureResult(ok: false, message: friendlyAdbError(result, fallback: "Failed to send text"))
    }
}
