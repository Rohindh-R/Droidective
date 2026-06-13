import Foundation

/// Assembles a lightweight bug-report zip: screenshot + recent logcat +
/// device info + (optional) app version. Built in a temp dir, zipped with
/// the macOS `zip` CLI, dropped in ~/Downloads/Droidective.
public struct BugReportService: Sendable {
    static let infoKeys = [
        "ro.product.brand",
        "ro.product.model",
        "ro.product.cpu.abi",
        "ro.build.version.release",
        "ro.build.version.sdk",
        "ro.build.display.id",
        "ro.serialno",
    ]

    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    public func create(serial: String, packageId: String?) async throws -> URL {
        let id = ScreenCaptureService.stamp()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bugreport-\(id)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let screenshot = try? await client.runBinary(on: serial, ["exec-out", "screencap", "-p"])
        if let screenshot, screenshot.exitCode == 0, !screenshot.stdout.isEmpty {
            try? screenshot.stdout.write(to: tmp.appendingPathComponent("screenshot.png"))
        }

        let log = try await client.run(
            on: serial, ["logcat", "-d", "-t", "2000"], maxOutputBytes: 20 * 1024 * 1024
        )
        try Data(log.stdout.utf8).write(to: tmp.appendingPathComponent("logcat.txt"))

        let props = try await DeviceProps.all(client: client, serial: serial)
        let info = Self.infoKeys.map { "\($0): \(props[$0] ?? "—")" }.joined(separator: "\n")
        try Data(info.utf8).write(to: tmp.appendingPathComponent("device-info.txt"))

        if let packageId, !packageId.isEmpty {
            let dump = try await client.run(on: serial, ["shell", "dumpsys", "package", packageId])
            let name = dump.stdout.firstMatch(of: /versionName=(\S+)/).map { String($0.1) } ?? "?"
            let code = dump.stdout.firstMatch(of: /versionCode=(\d+)/).map { String($0.1) } ?? "?"
            try Data("versionName=\(name)\nversionCode=\(code)".utf8)
                .write(to: tmp.appendingPathComponent("app-info.txt"))
        }

        let outDir = try ScreenCaptureService.ensureCaptureDir()
        let zipPath = outDir.appendingPathComponent("bug-report_\(id).zip")
        let runner = SystemProcessRunner()
        let zip = await runner.run(
            executable: "/usr/bin/zip",
            arguments: ["-r", "-j", zipPath.path, tmp.path],
            timeout: .seconds(60),
            maxOutputBytes: 10 * 1024 * 1024
        )
        guard zip.exitCode == 0 else {
            throw AppInspectionService.PullError.failed("Couldn't create the zip: \(zip.stderrText)")
        }
        return zipPath
    }
}
