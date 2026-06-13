import Foundation

/// Downloads the ADBKeyboard IME (needed for Unicode/% text input) and
/// installs it on the device.
public struct AdbKeyboardInstaller: Sendable {
    /// Upstream release APK of github.com/senzhk/ADBKeyBoard.
    static let apkURL = URL(string: "https://github.com/senzhk/ADBKeyBoard/raw/master/ADBKeyboard.apk")!

    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    public func install(serial: String) async -> FeatureResult {
        let apkPath: URL
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: Self.apkURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return FeatureResult(ok: false, message: "Couldn't download ADBKeyboard — check your connection.")
            }
            apkPath = FileManager.default.temporaryDirectory.appendingPathComponent("ADBKeyboard.apk")
            try? FileManager.default.removeItem(at: apkPath)
            try FileManager.default.moveItem(at: downloaded, to: apkPath)
        } catch {
            return FeatureResult(ok: false, message: "Couldn't download ADBKeyboard: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: apkPath) }

        guard let result = try? await client.run(
            on: serial, ["install", "-r", apkPath.path], timeout: .seconds(120)
        ) else {
            return FeatureResult(ok: false, message: "adb not found")
        }
        guard result.succeeded, result.stdout.range(of: "Success", options: .caseInsensitive) != nil else {
            return FeatureResult(ok: false, message: friendlyAdbError(result, fallback: "Install failed"))
        }
        return FeatureResult(ok: true, message: "ADBKeyboard installed — try sending the text again.")
    }
}
