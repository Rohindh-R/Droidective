import AVFoundation
import CoreMedia
import Foundation

/// Records the live mirror by passthrough-muxing the already-compressed H.264
/// sample buffers into an `.mp4` (no re-encode, negligible cost — so the mirror
/// stays fully live while recording). Driven from `MirrorSession`'s isolation.
/// The first appended sample must be a key frame; `MirrorSession` gates on that.
///
/// Only ever driven from `MirrorSession`'s serialized isolation (AVFoundation
/// owns its own internal threading), so it's safe to hand across the actor's
/// `await` on `finish()`.
final class MirrorRecorder: @unchecked Sendable {
    enum RecorderError: Error { case cannotConfigure }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false

    init(url: URL, formatDescription: CMVideoFormatDescription) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.cannotConfigure }
        writer.add(input)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    /// Finalize the container and return whether it completed. No-op cancel if
    /// nothing was ever written.
    func finish() async -> Bool {
        guard started else {
            writer.cancelWriting()
            return false
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed
    }
}
