import Foundation

/// Screen-recording options. The recorder maps these onto `ScrcpyServerParams`
/// for the in-app scrcpy client (bundled server) — no external scrcpy process.
/// `timeLimitSeconds` is enforced by the recording UI (the server has no
/// time-limit knob).
public struct ScreenRecordOptions: Sendable, Equatable {
    /// Longest side in px (0 = device size) → `max_size`.
    public var maxSize: Int
    /// Video bit-rate in Mbps (0 = server default) → `video_bit_rate`.
    public var bitRateMbps: Int
    /// Frame-rate cap (0 = unlimited) → `max_fps`.
    public var maxFps: Int
    /// Capture device audio (Android 11+; falls back to video-only otherwise).
    public var captureAudio: Bool
    /// Stop after N seconds (0 = unlimited); enforced by the UI.
    public var timeLimitSeconds: Int

    public init(
        maxSize: Int = 0,
        bitRateMbps: Int = 0,
        maxFps: Int = 0,
        captureAudio: Bool = true,
        timeLimitSeconds: Int = 0
    ) {
        self.maxSize = maxSize
        self.bitRateMbps = bitRateMbps
        self.maxFps = maxFps
        self.captureAudio = captureAudio
        self.timeLimitSeconds = timeLimitSeconds
    }
}
