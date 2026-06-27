import Foundation

/// Installs an APK onto a device with `adb install -r` (reinstall, keeping data
/// when the app is already there). The path is a local file handed to adb over
/// the sync protocol — no shell, so no quoting is needed. Install can take a
/// while, so it uses a generous timeout.
public struct AppInstallService: Sendable {
    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    public func install(apkPath: String, serial: String) async throws(AdbError) -> FeatureResult {
        let result = try await client.run(on: serial, ["install", "-r", apkPath], timeout: .seconds(180))
        return Self.parse(result)
    }

    /// Map adb's install output to a result. adb prints "Success" on success and
    /// "Failure [INSTALL_FAILED_…]" (or a streamed error line) on failure, often
    /// on a zero exit, so the text — not the exit code — is authoritative. The
    /// `message` is a short, plain-English reason for the toast; the full adb
    /// output is kept in `copyText` for the notifications panel.
    static func parse(_ result: AdbResult) -> FeatureResult {
        let combined = (result.stdout + "\n" + result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // adb prints a bare `Success` line on a successful (streamed) install.
        // Anchor to the start of a line so an error that merely mentions the word
        // (e.g. "not successful") isn't misread as success and masked.
        if combined.range(of: "(?m)^\\s*Success", options: .regularExpression) != nil {
            return FeatureResult(ok: true, message: "Installed")
        }
        let reason: String
        if let range = combined.range(of: "INSTALL_FAILED_[A-Z0-9_]+", options: .regularExpression) {
            reason = friendlyReason(String(combined[range]))
        } else if combined.contains("INSTALL_PARSE_FAILED") {
            reason = "The APK couldn't be parsed (corrupt or not an APK)."
        } else {
            reason = lastMeaningfulLine(combined) ?? "Unknown error."
        }
        return FeatureResult(ok: false, message: reason, copyText: combined.isEmpty ? nil : combined)
    }

    /// Plain-English reason for an adb `INSTALL_FAILED_*` code; the raw code is
    /// surfaced as-is when unmapped (still searchable).
    static func friendlyReason(_ code: String) -> String {
        switch code {
        case "INSTALL_FAILED_INSUFFICIENT_STORAGE": "Not enough storage on the device."
        case "INSTALL_FAILED_ALREADY_EXISTS": "The app is already installed."
        case "INSTALL_FAILED_VERSION_DOWNGRADE": "A newer version is already installed."
        case "INSTALL_FAILED_UPDATE_INCOMPATIBLE", "INSTALL_FAILED_DUPLICATE_PERMISSION":
            "It conflicts with an installed copy (signature or permission mismatch) — uninstall it first."
        case "INSTALL_FAILED_NO_MATCHING_ABIS": "The APK has no native code for this device's CPU."
        case "INSTALL_FAILED_OLDER_SDK": "The device's Android version is too old for this APK."
        case "INSTALL_FAILED_TEST_ONLY": "The APK is test-only — build a release APK."
        case "INSTALL_FAILED_INVALID_APK": "The APK is invalid or corrupt."
        case "INSTALL_FAILED_USER_RESTRICTED": "The device blocked it — allow USB install / unknown sources."
        case "INSTALL_FAILED_VERIFICATION_FAILURE": "Play Protect or verification blocked the install."
        default: code
        }
    }

    private static func lastMeaningfulLine(_ text: String) -> String? {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
