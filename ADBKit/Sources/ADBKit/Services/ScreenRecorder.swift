import Foundation

/// Screen recording: spawn on-device `screenrecord`, stop it gracefully
/// (SIGINT to the on-device process so the MP4 finalizes — SIGTERM to the
/// local adb client corrupts it), pull, optionally convert to GIF via ffmpeg.
/// screenrecord caps at ~3 min, has no audio, and stops on rotation.
public actor ScreenRecorder {
    public struct RecordingOutput: Sendable {
        public let localPath: URL
        public let gifPath: URL?
    }

    public enum RecordingError: Error, LocalizedError {
        case alreadyRecording
        case notRecording
        case pullFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already in progress."
            case .notRecording: return "No active recording."
            case .pullFailed(let reason): return reason
            }
        }
    }

    private let client: AdbClient
    private var child: Process?
    private var remotePath: String?
    private var serial: String?

    public init(client: AdbClient) {
        self.client = client
    }

    public var isRecording: Bool { child != nil }

    /// Filename the in-flight recording will pull as (for save dialogs).
    public var suggestedFileName: String? {
        remotePath.map { ($0 as NSString).lastPathComponent }
    }

    public func start(serial: String, options: ScreenRecordOptions = ScreenRecordOptions()) async throws {
        guard child == nil else { throw RecordingError.alreadyRecording }
        let adbPath = try await client.locator.adbPath()
        let remote = "/sdcard/droidective-\(ScreenCaptureService.stamp()).mp4"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "shell", "screenrecord"] + options.args() + [remote]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        child = process
        remotePath = remote
        self.serial = serial
    }

    public func stop(makeGif: Bool, to destination: URL? = nil) async throws -> RecordingOutput {
        guard let child, let remotePath, let serial else { throw RecordingError.notRecording }
        self.child = nil
        self.remotePath = nil
        self.serial = nil

        // Gracefully stop the on-device recorder so the file finalizes.
        _ = try await client.run(on: serial, ["shell", "pkill", "-INT", "screenrecord"])
        for _ in 0..<40 where child.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if child.isRunning {
            child.terminate()
        }

        let dest: URL
        if let destination {
            dest = destination
        } else {
            let dir = try ScreenCaptureService.ensureCaptureDir()
            dest = dir.appendingPathComponent((remotePath as NSString).lastPathComponent)
        }
        let pull = try await client.run(on: serial, ["pull", remotePath, dest.path], timeout: .seconds(120))
        guard pull.succeeded else {
            // Keep the remote file — it's the only copy of the recording.
            throw RecordingError.pullFailed(friendlyAdbError(
                pull, fallback: "Failed to pull the recording (it's still at \(remotePath) on the device)."
            ))
        }
        _ = try await client.run(on: serial, ["shell", "rm", "-f", remotePath])

        var gifPath: URL?
        if makeGif, let ffmpeg = await client.locator.resolve(.ffmpeg) {
            let gif = dest.deletingPathExtension().appendingPathExtension("gif")
            let runner = SystemProcessRunner()
            let output = await runner.run(
                executable: ffmpeg,
                arguments: ["-y", "-i", dest.path, "-vf", "fps=12,scale=480:-1:flags=lanczos", gif.path],
                timeout: .seconds(120),
                maxOutputBytes: 10 * 1024 * 1024
            )
            if output.exitCode == 0 {
                gifPath = gif
            }
        }
        return RecordingOutput(localPath: dest, gifPath: gifPath)
    }

    /// Abort without pulling (app quit).
    public func abort() {
        child?.interrupt()
        child = nil
        remotePath = nil
        serial = nil
    }
}
