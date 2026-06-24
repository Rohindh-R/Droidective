import Foundation

/// Screen recording built on the in-app scrcpy client (the bundled server), so
/// it needs no separate scrcpy install. A headless `MirrorSession` brings up the
/// device stream and records it straight to an `.mp4` (H.264 passthrough video +
/// AAC audio on Android 11+).
///
/// **Pause/resume is segmented.** scrcpy's encoder emits a key frame only at
/// stream start (it ignores the i-frame-interval hint), so a recording can't be
/// paused-and-resumed on one stream without corrupting the video (frames after a
/// resume would reference dropped ones). Instead each record/resume span is its
/// own session writing its own clean segment; `stop()` losslessly concatenates
/// the segments with ffmpeg. The finished file is handed to the editor; nothing
/// lands in the capture folder until the user saves.
public actor ScreenRecorder {
    public enum RecordingError: Error, LocalizedError {
        case alreadyRecording
        case notRecording
        case startFailed(String)
        case concatFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already in progress."
            case .notRecording: return "No active recording."
            case .startFailed(let reason): return reason
            case .concatFailed(let reason): return "Couldn’t assemble the recording: \(reason)"
            }
        }
    }

    private let client: AdbClient
    private let server: ScrcpyServerInfo
    /// Bundled ffmpeg path, for concatenating paused/resumed segments. Without it
    /// only single-segment (never-paused) recordings are supported.
    private let ffmpegPath: String?

    private var session: MirrorSession?
    private var currentURL: URL?
    private var segments: [URL] = []
    private var serial = ""
    private var options = ScreenRecordOptions()

    public init(client: AdbClient, server: ScrcpyServerInfo, ffmpegPath: String? = nil) {
        self.client = client
        self.server = server
        self.ffmpegPath = ffmpegPath
    }

    /// Actively capturing or holding finished segments (paused).
    public var isRecording: Bool { session != nil || !segments.isEmpty }
    /// Recording started but currently paused between segments.
    public var isPaused: Bool { session == nil && !segments.isEmpty }

    public func start(serial: String, options: ScreenRecordOptions = ScreenRecordOptions()) async throws {
        guard !isRecording else { throw RecordingError.alreadyRecording }
        self.serial = serial
        self.options = options
        try await startSegment()
    }

    /// Finalize the current segment (keeping it) so a later resume appends a new
    /// one. No-op if already paused.
    public func pause() async {
        await finalizeSegment()
    }

    /// Begin a fresh segment after a pause.
    public func resume() async throws {
        guard isPaused else { return }
        try await startSegment()
    }

    /// Stop, finalize the last segment, and return the recording — a single
    /// segment as-is, or all segments concatenated losslessly.
    public func stop() async throws -> URL {
        await finalizeSegment()
        let segs = segments
        segments = []
        guard let first = segs.first else { throw RecordingError.notRecording }
        // Concatenating (>1) already rewrites the container via ffmpeg; a single
        // segment is remuxed too so AVFoundation can decode it (the editor's
        // player + previews otherwise fail on AVAssetWriter's passthrough output).
        guard segs.count > 1 else { return await remux(first) ?? first }
        return try await concatenate(segs)
    }

    private func remux(_ source: URL) async -> URL? {
        guard let ffmpegPath else { return nil }
        let output = Self.tempURL(ext: "mp4")
        let result = await SystemProcessRunner().run(
            executable: ffmpegPath,
            arguments: VideoEditing.remuxArguments(input: source.path, output: output.path),
            timeout: .seconds(60), maxOutputBytes: 4 * 1024 * 1024)
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        try? FileManager.default.removeItem(at: source)
        return output
    }

    /// Abort and discard everything (view dismissed / app quit).
    public func abort() async {
        if let session { await session.stop() }
        let leftovers = segments + [currentURL].compactMap { $0 }
        session = nil
        currentURL = nil
        segments = []
        for url in leftovers { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Segments

    private func startSegment() async throws {
        let params = ScrcpyServerParams(
            scid: UInt32.random(in: 1 ... 0x7fff_ffff),
            audio: options.captureAudio,
            control: false,
            maxSize: options.maxSize,
            videoBitRate: options.bitRateMbps > 0 ? options.bitRateMbps * 1_000_000 : 0,
            maxFps: options.maxFps)
        let config = MirrorTransport.Configuration(
            serial: serial, params: params,
            serverVersion: server.version, localJarPath: server.jarPath)
        let session = MirrorSession(adb: client, config: config)
        // start() drives decode + recording from the session's own task; the
        // returned display stream is bounded and left undrained (we only record).
        _ = await session.start()

        let temp = Self.tempURL(ext: "mp4")
        // Arm recording up front; the session creates the recorder when the config
        // packet lands so this segment captures from its first key frame.
        try await session.startRecording(to: temp)
        guard await Self.waitUntilStreaming(session: session) else {
            await session.stop()
            throw RecordingError.startFailed("Couldn’t get video from the device.")
        }
        self.session = session
        self.currentURL = temp
    }

    private func finalizeSegment() async {
        guard let session, let currentURL else { return }
        self.session = nil
        self.currentURL = nil
        _ = try? await session.stopRecording(url: currentURL)
        await session.stop()
        segments.append(currentURL)
    }

    private static func waitUntilStreaming(session: MirrorSession) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            if await session.currentDimensions() != nil { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    private func concatenate(_ segments: [URL]) async throws -> URL {
        guard let ffmpegPath else {
            throw RecordingError.concatFailed("ffmpeg is unavailable")
        }
        let listURL = Self.tempURL(ext: "txt")
        let body = segments.map { "file '\($0.path)'" }.joined(separator: "\n")
        do {
            try body.write(to: listURL, atomically: true, encoding: .utf8)
        } catch {
            throw RecordingError.concatFailed(error.localizedDescription)
        }
        let output = Self.tempURL(ext: "mp4")
        let result = await SystemProcessRunner().run(
            executable: ffmpegPath,
            arguments: VideoEditing.concatArguments(listFile: listURL.path, output: output.path),
            timeout: .seconds(120), maxOutputBytes: 4 * 1024 * 1024)
        try? FileManager.default.removeItem(at: listURL)
        for url in segments { try? FileManager.default.removeItem(at: url) }
        guard result.exitCode == 0 else {
            let tail = result.stderrText.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw RecordingError.concatFailed(tail.isEmpty ? "ffmpeg failed" : tail)
        }
        return output
    }

    private static func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("droidective-recording-\(ScreenCaptureService.stamp())-\(UInt32.random(in: 0 ... 0xffff_ffff))")
            .appendingPathExtension(ext)
    }
}
