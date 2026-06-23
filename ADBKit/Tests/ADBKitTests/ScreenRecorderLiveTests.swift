import AVFoundation
import Foundation
import Testing
@testable import ADBKit

/// End-to-end screen recording against a real device via the scrcpy server,
/// confirming the rebuilt recorder produces a playable MP4 with video + audio
/// (no desktop scrcpy binary). Disabled by default; run with
/// `MIRROR_LIVE_TEST=1 swift test`.
@Suite struct ScreenRecorderLiveTests {
    private static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["MIRROR_LIVE_TEST"] == "1"
    }

    @Test(.enabled(if: liveEnabled))
    func recordsVideoAndAudioViaBundledServer() async throws {
        let serial = ProcessInfo.processInfo.environment["MIRROR_SERIAL"] ?? "emulator-5554"
        let locator = ToolLocator()
        let adb = AdbClient(locator: locator)
        // The test reuses the installed scrcpy's server payload; in the app the
        // identical payload is bundled (BundledTools).
        guard let server = await ScrcpyServerLocator.resolve(locator: locator) else {
            Issue.record("scrcpy is not installed")
            return
        }

        let recorder = ScreenRecorder(client: adb, server: server)
        try await recorder.start(
            serial: serial, options: ScreenRecordOptions(maxSize: 800, captureAudio: true))
        try await Task.sleep(for: .seconds(3))
        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        // Map to Sendable scalars inside the await so no AVAssetTrack crosses an
        // isolation boundary (avoids the strict-concurrency trap).
        let duration = try await asset.load(.duration).seconds
        let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty

        #expect(duration > 0)
        #expect(hasVideo)
        #expect(hasAudio)
    }
}
