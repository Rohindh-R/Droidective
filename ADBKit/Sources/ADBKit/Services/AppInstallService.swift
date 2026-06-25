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
    /// on a zero exit, so the text — not the exit code — is authoritative.
    static func parse(_ result: AdbResult) -> FeatureResult {
        let combined = result.stdout + "\n" + result.stderr
        if combined.range(of: "Success", options: .caseInsensitive) != nil {
            return FeatureResult(ok: true, message: "Installed")
        }
        if let range = combined.range(of: "INSTALL_FAILED_[A-Z_]+", options: .regularExpression) {
            return FeatureResult(ok: false, message: "Install failed — \(combined[range])")
        }
        let lastLine = combined
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return FeatureResult(ok: false, message: lastLine ?? "Install failed")
    }
}
