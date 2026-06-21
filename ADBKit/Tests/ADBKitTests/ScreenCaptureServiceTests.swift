import Foundation
import Testing
@testable import ADBKit

@Suite struct ScreenCaptureServiceTests {
    private static let screencapArgs = ["-s", "S1", "exec-out", "screencap", "-p"]

    @Test func captureScreenshotDataReturnsRawBytes() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: Self.screencapArgs, stdout: "PNGBYTES")
        let service = ScreenCaptureService(client: await makeTestClient(runner: runner))

        let data = try await service.captureScreenshotData(serial: "S1")

        #expect(data == Data("PNGBYTES".utf8))
        #expect(runner.invocations.last?.arguments == Self.screencapArgs)
    }

    @Test func captureScreenshotDataThrowsOnEmptyOutput() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: Self.screencapArgs, stdout: "", exitCode: 0)
        let service = ScreenCaptureService(client: await makeTestClient(runner: runner))

        await #expect(throws: ScreenCaptureService.CaptureError.self) {
            _ = try await service.captureScreenshotData(serial: "S1")
        }
    }

    @Test func captureScreenshotWritesBytesToDestination() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: Self.screencapArgs, stdout: "PNGBYTES")
        let service = ScreenCaptureService(client: await makeTestClient(runner: runner))
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbkit-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: dest) }

        let url = try await service.captureScreenshot(serial: "S1", to: dest)

        #expect(url == dest)
        #expect(try Data(contentsOf: dest) == Data("PNGBYTES".utf8))
    }
}
