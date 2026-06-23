import AVFoundation
import CoreMedia
import Foundation

/// Records the live mirror by passthrough-muxing the already-compressed H.264
/// sample buffers into an `.mp4` (no re-encode, negligible cost — so the mirror
/// stays fully live while recording). When the session carries device audio, a
/// second track re-encodes the raw PCM to AAC alongside the video. The first
/// appended video sample must be a key frame; `MirrorSession` gates on that, and
/// the writer session starts on that frame's timestamp so audio shares the clock.
///
/// Only ever driven from `MirrorSession`'s serialized isolation (AVFoundation
/// owns its own internal threading), so it's safe to hand across the actor's
/// `await` on `finish()`.
final class MirrorRecorder: @unchecked Sendable {
    enum RecorderError: Error { case cannotConfigure }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let audioFormat: CMAudioFormatDescription?
    private var started = false

    /// - Parameter includeAudio: add an AAC audio track fed by `appendAudio`.
    ///   Pass true only when the session actually supplies PCM (raw audio on).
    init(url: URL, formatDescription: CMVideoFormatDescription, includeAudio: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: formatDescription)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotConfigure }
        writer.add(videoInput)

        if includeAudio {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: MirrorAudioPlayer.sampleRate,
                AVNumberOfChannelsKey: Int(MirrorAudioPlayer.channelCount),
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.cannotConfigure }
            writer.add(input)
            audioInput = input
            audioFormat = Self.pcmFormat()
        } else {
            audioInput = nil
            audioFormat = nil
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    /// Append one chunk of raw interleaved s16le PCM at `pts` (device clock). A
    /// no-op until the video session has started, so audio shares the video's
    /// timeline; a little leading audio before the first key frame is dropped.
    func appendAudio(_ pcm: Data, pts: CMTime) {
        guard started, let audioInput, let audioFormat, audioInput.isReadyForMoreMediaData,
              let sampleBuffer = Self.audioSampleBuffer(pcm, pts: pts, format: audioFormat)
        else { return }
        audioInput.append(sampleBuffer)
    }

    /// Finalize the container and return whether it completed. No-op cancel if
    /// nothing was ever written.
    func finish() async -> Bool {
        guard started else {
            writer.cancelWriting()
            return false
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed
    }

    // MARK: - PCM → CMSampleBuffer

    private static func pcmFormat() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: MirrorAudioPlayer.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: MirrorAudioPlayer.channelCount, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format)
        return format
    }

    private static func audioSampleBuffer(
        _ pcm: Data, pts: CMTime, format: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        let frameCount = pcm.count / 4  // 2 channels × 2 bytes
        guard frameCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pcm.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: pcm.count, flags: 0, blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copied = pcm.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: pcm.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(MirrorAudioPlayer.sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}
