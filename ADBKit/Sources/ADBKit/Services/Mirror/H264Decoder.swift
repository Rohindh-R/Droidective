import CoreMedia
import Foundation
import VideoToolbox

/// A decoded frame's image buffer. `CVImageBuffer` isn't Sendable; it's only
/// read (never mutated) after decode, so box it to cross isolation.
struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVImageBuffer
}

/// Hardware H.264 decode via VideoToolbox. Used only to keep the latest decoded
/// frame for screenshots — live display goes through `AVSampleBufferDisplayLayer`
/// fed the compressed buffers directly. Drive from a single isolation domain
/// (`MirrorSession` owns it); decoded frames arrive on a VideoToolbox queue via
/// the Sendable `onImage` callback.
final class H264Decoder {
    private var session: VTDecompressionSession?

    /// Delivered on a VideoToolbox queue — keep it Sendable and self-free.
    var onImage: (@Sendable (PixelBufferBox, CMTime) -> Void)?

    /// (Re)create the decompression session for a format description.
    func setFormat(_ formatDescription: CMVideoFormatDescription) {
        invalidate()
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created)
        session = created
    }

    func decode(_ sampleBuffer: CMSampleBuffer) {
        guard let session else { return }
        let sink = onImage
        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { status, _, imageBuffer, framePTS, _ in
            guard status == noErr, let imageBuffer else { return }
            sink?(PixelBufferBox(buffer: imageBuffer), framePTS)
        }
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit { invalidate() }
}
