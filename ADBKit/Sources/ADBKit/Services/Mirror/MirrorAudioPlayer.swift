import AVFoundation
import Foundation

/// Plays scrcpy raw audio — signed 16-bit little-endian PCM, 48 kHz, stereo,
/// interleaved (`audio_codec=raw`, `AV_CODEC_ID_PCM_S16LE`) — live through an
/// `AVAudioEngine`.
///
/// Buffers are scheduled as they arrive and played with the engine's own small
/// queue. A live mirror tolerates a little jitter but not the added latency of
/// PTS-accurate A/V sync, which scrcpy itself doesn't attempt for mirroring —
/// each stream just plays as fast as it arrives.
///
/// `AVAudioEngine` isn't `Sendable`, so this is boxed `@unchecked` and every
/// call is funnelled through the view model's single audio task (built and
/// driven off the main thread — its construction blocks on Core Audio XPC).
public final class MirrorAudioPlayer: @unchecked Sendable {
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 2

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var running = false

    public init() {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: Self.channelCount) else {
            preconditionFailure("48 kHz stereo is always a valid AVAudioFormat")
        }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Start the engine and begin playback. Idempotent. Throws if Core Audio
    /// can't start the engine (e.g. no output device).
    public func start() throws {
        guard !running else { return }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    public func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        running = false
    }

    /// Convert one chunk of interleaved s16le PCM to the engine's float format
    /// and schedule it. No-op until `start()` and for empty/partial frames.
    public func enqueue(pcmS16LE data: Data) {
        guard running else { return }
        // 2 channels × 2 bytes per sample = 4 bytes per stereo frame.
        let frameCount = data.count / 4
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let left = buffer.floatChannelData?[0],
              let right = buffer.floatChannelData?[1] else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let scale: Float = 1.0 / 32_768.0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            // loadUnaligned reads host-endian (little on every Apple platform),
            // matching the wire format; the Data buffer may be odd-aligned.
            for frame in 0 ..< frameCount {
                let l = raw.loadUnaligned(fromByteOffset: frame * 4, as: Int16.self)
                let r = raw.loadUnaligned(fromByteOffset: frame * 4 + 2, as: Int16.self)
                left[frame] = Float(l) * scale
                right[frame] = Float(r) * scale
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}
