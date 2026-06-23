import AVFoundation
import CoreMedia
import Foundation

/// Orchestrates one in-app mirroring session end to end: brings up the transport,
/// drives the wire-protocol decoder, and turns frame packets into `CMSampleBuffer`s
/// that serve all three consumers from a single device stream —
///
/// - **display**: the compressed sample buffers are streamed out for an
///   `AVSampleBufferDisplayLayer` to decode and show;
/// - **screenshot**: the same buffers are decoded by VideoToolbox so the latest
///   frame is always available as a pixel buffer;
/// - **record**: when active, the buffers are passthrough-muxed to an `.mp4`.
///
/// Recording therefore never interrupts the live, controllable mirror.
public actor MirrorSession {
    public struct DisplaySample: @unchecked Sendable {
        public let sampleBuffer: CMSampleBuffer
    }

    public struct Snapshot: @unchecked Sendable {
        public let imageBuffer: CVImageBuffer
        public let width: Int
        public let height: Int
    }

    public enum SessionError: Error, Sendable {
        case notStreaming
        case notRecording
    }

    private let transport: MirrorTransport
    private let decoder = H264Decoder()

    private var formatDescription: CMVideoFormatDescription?
    private var dimensions: (width: Int, height: Int)?
    private var latest: Snapshot?

    private var consumeTask: Task<Void, Never>?
    private var controlConsumeTask: Task<Void, Never>?
    private var displayContinuation: AsyncThrowingStream<DisplaySample, Error>.Continuation?
    private var clipboardStream: AsyncStream<String>?
    private var clipboardContinuation: AsyncStream<String>.Continuation?

    private var recorder: MirrorRecorder?
    private var recorderStarted = false

    public init(adb: AdbClient, config: MirrorTransport.Configuration) {
        transport = MirrorTransport(adb: adb, config: config)
    }

    public init(transport: MirrorTransport) {
        self.transport = transport
    }

    /// Begin the session; the returned stream yields compressed sample buffers
    /// for the display layer until `stop()` or an error.
    public func start() -> AsyncThrowingStream<DisplaySample, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DisplaySample.self)
        displayContinuation = continuation
        let (clipboard, clipboardSink) = AsyncStream.makeStream(of: String.self)
        clipboardStream = clipboard
        clipboardContinuation = clipboardSink
        decoder.onImage = { [weak self] box, _ in
            guard let self else { return }
            Task { await self.storeLatest(box) }
        }
        consumeTask = Task { await self.run(continuation) }
        return stream
    }

    public func stop() async {
        consumeTask?.cancel()
        consumeTask = nil
        controlConsumeTask?.cancel()
        controlConsumeTask = nil
        decoder.invalidate()
        await transport.stop()
        if recorder != nil {
            _ = await recorder?.finish()
            recorder = nil
            recorderStarted = false
        }
        displayContinuation?.finish()
        displayContinuation = nil
        clipboardContinuation?.finish()
        clipboardContinuation = nil
    }

    /// The latest decoded frame, for a screenshot.
    public func snapshot() -> Snapshot? { latest }

    public func currentDimensions() -> (width: Int, height: Int)? { dimensions }

    /// A Sendable sink for control messages (touch/key), or nil if control isn't
    /// enabled in the params. Cache it and call synchronously to preserve event
    /// order (the underlying socket send is ordered).
    public func controlSender() async -> (@Sendable (ScrcpyControlMessage) -> Void)? {
        guard let sink = await transport.controlSender() else { return nil }
        return { message in sink(message.serialized()) }
    }

    /// Clipboard text the device pushed back (a device-side copy, or a reply to
    /// GET_CLIPBOARD). Subscribe and mirror it onto the Mac pasteboard.
    public func incomingClipboards() -> AsyncStream<String>? { clipboardStream }

    public func isRecording() -> Bool { recorder != nil }

    /// Start passthrough recording to `url`. Appending begins at the next key
    /// frame so the file opens on a sync sample.
    public func startRecording(to url: URL) throws {
        guard let formatDescription else { throw SessionError.notStreaming }
        recorder = try MirrorRecorder(url: url, formatDescription: formatDescription)
        recorderStarted = false
    }

    /// Finalize the recording and return the file URL it was written to.
    public func stopRecording(url: URL) async throws -> URL {
        guard let recorder else { throw SessionError.notRecording }
        _ = await recorder.finish()
        self.recorder = nil
        recorderStarted = false
        return url
    }

    // MARK: - Stream consumption

    private func run(_ continuation: AsyncThrowingStream<DisplaySample, Error>.Continuation) async {
        do {
            let bytes = try await transport.start()
            if let control = await transport.controlIncoming() {
                controlConsumeTask = Task { [weak self] in
                    var deviceDecoder = ScrcpyDeviceMessageDecoder()
                    for await chunk in control {
                        await self?.handleDeviceMessages(deviceDecoder.consume(chunk))
                    }
                }
            }
            var streamDecoder = ScrcpyStreamDecoder(tunnelForward: true)
            for try await chunk in bytes {
                if Task.isCancelled { break }
                for event in streamDecoder.consume(chunk) {
                    handle(event, continuation)
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func handle(
        _ event: ScrcpyStreamDecoder.Event,
        _ continuation: AsyncThrowingStream<DisplaySample, Error>.Continuation
    ) {
        switch event {
        case let .videoHeader(_, _, width, height, _):
            dimensions = (width, height)
        case .deviceName:
            break
        case let .packet(header, payload):
            if header.isConfig {
                if let sets = H264NAL.parameterSets(fromAnnexB: payload),
                   let format = H264Format.formatDescription(sps: sets.sps, pps: sets.pps) {
                    formatDescription = format
                    decoder.setFormat(format)
                }
                return
            }
            guard let formatDescription else { return }
            let pts = CMTime(value: CMTimeValue(header.pts), timescale: 1_000_000)
            let avcc = H264NAL.avcc(fromAnnexB: payload)
            guard let sampleBuffer = H264Format.sampleBuffer(
                avcc: avcc, formatDescription: formatDescription, pts: pts) else { return }

            continuation.yield(DisplaySample(sampleBuffer: sampleBuffer))
            decoder.decode(sampleBuffer)

            if let recorder {
                if recorderStarted || header.isKeyFrame {
                    recorderStarted = true
                    recorder.append(sampleBuffer)
                }
            }
        }
    }

    private func handleDeviceMessages(_ messages: [ScrcpyDeviceMessage]) {
        for message in messages {
            if case let .clipboard(text) = message {
                clipboardContinuation?.yield(text)
            }
        }
    }

    private func storeLatest(_ box: PixelBufferBox) {
        latest = Snapshot(
            imageBuffer: box.buffer,
            width: CVPixelBufferGetWidth(box.buffer),
            height: CVPixelBufferGetHeight(box.buffer))
    }
}
