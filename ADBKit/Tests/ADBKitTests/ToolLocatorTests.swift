import Foundation
import Testing
@testable import ADBKit

@Suite struct ToolLocatorTests {
    private func makeBundledDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbkit-bundled-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeExecutable(_ url: URL) {
        FileManager.default.createFile(
            atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755]
        )
    }

    @Test func bundledToolIsPreferredOverSystemInstalls() async {
        let dir = makeBundledDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scrcpy = dir.appendingPathComponent("scrcpy")
        writeExecutable(scrcpy)

        let locator = ToolLocator(
            runner: MockProcessRunner(),
            environment: ["ANDROID_HOME": "/opt/android"],
            bundledToolsDirectory: dir
        )
        #expect(await locator.resolve(.scrcpy) == scrcpy.path)
    }

    @Test func emptyBundledDirectoryIsNotFalselyMatched() async {
        let dir = makeBundledDir() // empty — no binaries inside
        defer { try? FileManager.default.removeItem(at: dir) }
        // With no bundled copy present, resolution must skip the bundled
        // directory (the path inside it doesn't exist) and fall through to the
        // normal system search — it must never return the non-existent
        // bundled path itself.
        let locator = ToolLocator(
            runner: MockProcessRunner(),
            environment: [:],
            bundledToolsDirectory: dir
        )
        let resolved = await locator.resolve(.ffmpeg)
        #expect(resolved != dir.appendingPathComponent("ffmpeg").path)
    }
}
