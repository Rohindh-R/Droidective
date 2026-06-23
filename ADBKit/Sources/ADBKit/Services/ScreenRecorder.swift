import Foundation

/// Screen recording built on the in-app scrcpy client (the bundled server), so
/// it needs no separate scrcpy install. A headless `MirrorSession` brings up the
/// device stream and records it straight to an `.mp4` (H.264 passthrough video +
/// AAC audio on Android 11+) — none of `adb shell screenrecord`'s limits (no
/// ~3-min cap, audio, survives rotation). The finished temp file is handed to the
/// editor; nothing lands in the capture folder until the user exports.
public actor ScreenRecorder {
    public enum RecordingError: Error, LocalizedError {
        case alreadyRecording
        case notRecording
        case startFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already in progress."
            case .notRecording: return "No active recording."
            case .startFailed(let reason): return reason
            }
        }
    }

    private let client: AdbClient
    private let server: ScrcpyServerInfo
    private var session: MirrorSession?
    private var localPath: URL?

    /// - Parameter server: the bundled `scrcpy-server` info (jar path + version),
    ///   resolved by the App layer from `Bundle.main`.
    public init(client: AdbClient, server: ScrcpyServerInfo) {
        self.client = client
        self.server = server
    }

    public var isRecording: Bool { session != nil }

    public func start(serial: String, options: ScreenRecordOptions = ScreenRecordOptions()) async throws {
        guard session == nil else { throw RecordingError.alreadyRecording }
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

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("droidective-recording-\(ScreenCaptureService.stamp()).mp4")
        // Arm recording up front; the session creates the recorder when the config
        // packet lands so the first key frame is captured. Then confirm the stream
        // actually came up (app_process boot + first frame) within ~15s.
        try await session.startRecording(to: temp)
        guard await Self.waitUntilStreaming(session: session) else {
            await session.stop()
            throw RecordingError.startFailed("Couldn't get video from the device.")
        }
        self.session = session
        self.localPath = temp
    }

    private static func waitUntilStreaming(session: MirrorSession) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            // Known dimensions mean the video header arrived — video is flowing,
            // and the recorder is armed to catch the first key frame.
            if await session.currentDimensions() != nil { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    /// Stop recording, finalize the MP4, and return the finished file.
    public func stop() async throws -> URL {
        guard let session, let localPath else { throw RecordingError.notRecording }
        self.session = nil
        self.localPath = nil
        _ = try? await session.stopRecording(url: localPath)
        await session.stop()
        return localPath
    }

    /// Abort and discard (view dismissed / app quit): tear down the session and
    /// remove the temp file.
    public func abort() async {
        guard let session else { return }
        let temp = localPath
        self.session = nil
        self.localPath = nil
        await session.stop()
        if let temp { try? FileManager.default.removeItem(at: temp) }
    }
}
