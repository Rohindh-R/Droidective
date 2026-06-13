import Foundation

/// Pull captures from the device to the user's Mac. Binary captures use
/// `exec-out` raw bytes (text decoding would corrupt PNG/MP4). Files land in
/// ~/Downloads/Droidective.
public struct ScreenCaptureService: Sendable {
    public enum CaptureError: Error, LocalizedError {
        case emptyScreenshot

        public var errorDescription: String? {
            "Screenshot was empty — is a device connected and unlocked?"
        }
    }

    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    /// Filesystem-safe timestamp for capture filenames.
    public static func stamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// Ensure (and return) the ~/Downloads/Droidective capture directory.
    public static func ensureCaptureDir() throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dir = downloads.appendingPathComponent("Droidective", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Capture a PNG screenshot. `destination: nil` falls back to a
    /// timestamped file in ~/Downloads/Droidective.
    public func captureScreenshot(serial: String, to destination: URL? = nil) async throws -> URL {
        let output = try await client.runBinary(on: serial, ["exec-out", "screencap", "-p"])
        guard output.exitCode == 0, !output.stdout.isEmpty else {
            throw CaptureError.emptyScreenshot
        }
        let file: URL
        if let destination {
            file = destination
        } else {
            let dir = try Self.ensureCaptureDir()
            file = dir.appendingPathComponent("screenshot_\(Self.stamp()).png")
        }
        try output.stdout.write(to: file)
        return file
    }
}
