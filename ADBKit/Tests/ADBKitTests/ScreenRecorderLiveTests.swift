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

@Suite struct ScreenRecorderPauseResumeLiveTests {
    private static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["MIRROR_LIVE_TEST"] == "1"
    }

    @Test(.enabled(if: liveEnabled))
    func pauseResumeProducesOneConcatenatedFile() async throws {
        let serial = ProcessInfo.processInfo.environment["MIRROR_SERIAL"] ?? "emulator-5554"
        let locator = ToolLocator()
        let adb = AdbClient(locator: locator)
        guard let server = await ScrcpyServerLocator.resolve(locator: locator) else {
            Issue.record("scrcpy not installed"); return
        }
        // Resolve the installed ffmpeg for the concat step (the app uses the
        // bundled one).
        let ffmpeg = await locator.resolve(.ffmpeg)
        let recorder = ScreenRecorder(client: adb, server: server, ffmpegPath: ffmpeg)

        try await recorder.start(serial: serial, options: ScreenRecordOptions(maxSize: 800))
        try await Task.sleep(for: .seconds(2))
        await recorder.pause()
        let pausedFlag = await recorder.isPaused
        try await Task.sleep(for: .seconds(1))
        try await recorder.resume()
        try await Task.sleep(for: .seconds(2))
        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty

        #expect(pausedFlag)
        #expect(hasVideo)
        // Two ~2s segments stitched, paused second excluded → well over one segment.
        #expect(duration > 2.5)
    }
}

@Suite struct RecordingThumbnailLiveTests {
    private static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["MIRROR_LIVE_TEST"] == "1"
    }

    @Test(.enabled(if: liveEnabled))
    func recordingProducesAThumbnail() async throws {
        let serial = ProcessInfo.processInfo.environment["MIRROR_SERIAL"] ?? "emulator-5554"
        let locator = ToolLocator()
        let adb = AdbClient(locator: locator)
        guard let server = await ScrcpyServerLocator.resolve(locator: locator) else {
            Issue.record("scrcpy not installed"); return
        }
        let recorder = ScreenRecorder(client: adb, server: server)
        try await recorder.start(serial: serial, options: ScreenRecordOptions(maxSize: 800))
        try await Task.sleep(for: .seconds(3))
        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        guard let ffmpeg = await locator.resolve(.ffmpeg) else {
            Issue.record("ffmpeg not installed"); return
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-test-\(UInt32.random(in: 0 ... 0xffff)).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = await SystemProcessRunner().run(
            executable: ffmpeg,
            arguments: VideoEditing.thumbnailArguments(input: url.path, output: out.path),
            timeout: .seconds(20), maxOutputBytes: 1_000_000)
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        print("THUMB FFMPEG: exit=\(result.exitCode) size=\(size ?? 0)")
        #expect(result.exitCode == 0)
        #expect((size ?? 0) > 0)
    }
}

@Suite struct RecordingPlayabilityLiveTests {
    private static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["MIRROR_LIVE_TEST"] == "1"
    }

    private func decodable(_ url: URL) async -> Bool {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        return (try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image) != nil
    }

    /// The finished recording (remuxed via ffmpeg in stop()) must be decodable by
    /// AVFoundation, so the editor's player and previews work — AVAssetWriter's
    /// raw passthrough output is not (it fails with -11821).
    @Test(.enabled(if: liveEnabled))
    func finishedRecordingIsAVFoundationDecodable() async throws {
        let serial = ProcessInfo.processInfo.environment["MIRROR_SERIAL"] ?? "emulator-5554"
        let locator = ToolLocator()
        let adb = AdbClient(locator: locator)
        guard let server = await ScrcpyServerLocator.resolve(locator: locator),
              let ffmpeg = await locator.resolve(.ffmpeg) else { Issue.record("tools missing"); return }
        // Pass ffmpeg so stop() remuxes, exactly like the app.
        let recorder = ScreenRecorder(client: adb, server: server, ffmpegPath: ffmpeg)
        try await recorder.start(serial: serial, options: ScreenRecordOptions(maxSize: 800))
        try await Task.sleep(for: .seconds(3))
        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        let ok = await decodable(url)
        #expect(ok)
    }
}
