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
        case notRecording
    }

    private let transport: MirrorTransport
    private let decoder = H264Decoder()
    /// Whether the session requested device audio — gates adding an audio track
    /// to recordings.
    private let recordsAudio: Bool

    private var formatDescription: CMVideoFormatDescription?
    private var dimensions: (width: Int, height: Int)?
    private var latest: Snapshot?

    private var consumeTask: Task<Void, Never>?
    private var controlConsumeTask: Task<Void, Never>?
    private var audioConsumeTask: Task<Void, Never>?
    private var displayContinuation: AsyncThrowingStream<DisplaySample, Error>.Continuation?
    private var clipboardStream: AsyncStream<String>?
    private var clipboardContinuation: AsyncStream<String>.Continuation?
    private var audioPCMStream: AsyncStream<Data>?
    private var audioPCMContinuation: AsyncStream<Data>.Continuation?

    private var recorder: MirrorRecorder?
    private var recorderStarted = false
    /// Set by `startRecording` before the format is known; consumed when the
    /// config packet arrives to create the recorder in time for the first frame.
    private var pendingRecordURL: URL?

    public init(adb: AdbClient, config: MirrorTransport.Configuration) {
        transport = MirrorTransport(adb: adb, config: config)
        recordsAudio = config.params.audio
    }

    public init(transport: MirrorTransport, recordsAudio: Bool = false) {
        self.transport = transport
        self.recordsAudio = recordsAudio
    }

    /// Begin the session; the returned stream yields compressed sample buffers
    /// for the display layer until `stop()` or an error.
    public func start() -> AsyncThrowingStream<DisplaySample, Error> {
        // Bounded so a headless recording session (which never drains the display
        // stream) doesn't buffer frames without limit; under load the renderer
        // just drops stale frames rather than lagging.
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: DisplaySample.self, bufferingPolicy: .bufferingNewest(3))
        displayContinuation = continuation
        let (clipboard, clipboardSink) = AsyncStream.makeStream(of: String.self)
        clipboardStream = clipboard
        clipboardContinuation = clipboardSink
        let (audio, audioSink) = AsyncStream.makeStream(of: Data.self)
        audioPCMStream = audio
        audioPCMContinuation = audioSink
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
        audioConsumeTask?.cancel()
        audioConsumeTask = nil
        decoder.invalidate()
        await transport.stop()
        pendingRecordURL = nil
        if recorder != nil {
            _ = await recorder?.finish()
            recorder = nil
            recorderStarted = false
        }
        displayContinuation?.finish()
        displayContinuation = nil
        clipboardContinuation?.finish()
        clipboardContinuation = nil
        audioPCMContinuation?.finish()
        audioPCMContinuation = nil
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

    /// Raw device audio as interleaved s16le PCM (48 kHz, stereo) when the device
    /// supplies it, or nil if audio wasn't requested. The stream yields nothing
    /// and finishes if the device disabled audio (Android < 11) — the mirror then
    /// stays silent but otherwise unaffected. Feed chunks to a `MirrorAudioPlayer`.
    public func audioPCM() -> AsyncStream<Data>? { audioPCMStream }

    public func isRecording() -> Bool { recorder != nil || pendingRecordURL != nil }

    /// Arm passthrough recording to `url`. If the video format is already known
    /// the recorder is created now; otherwise it's created the instant the config
    /// packet arrives — which immediately precedes the stream's first key frame,
    /// so a fresh session captures from that first frame rather than waiting for
    /// the next periodic key frame (seconds away). Appending always opens on a
    /// key frame so the file starts on a sync sample.
    public func startRecording(to url: URL) throws {
        pendingRecordURL = url
        if let formatDescription, recorder == nil {
            try activateRecorder(formatDescription: formatDescription, url: url)
        }
    }

    private func activateRecorder(formatDescription: CMVideoFormatDescription, url: URL) throws {
        recorder = try MirrorRecorder(
            url: url, formatDescription: formatDescription, includeAudio: recordsAudio)
        recorderStarted = false
        pendingRecordURL = nil
    }

    /// Finalize the recording and return the file URL it was written to.
    public func stopRecording(url: URL) async throws -> URL {
        pendingRecordURL = nil
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
            if let audio = await transport.audioByteStream() {
                audioConsumeTask = Task { [weak self] in
                    await self?.consumeAudio(audio)
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
                    // Arm a pending recording now so the key frame that follows
                    // this config packet is the recording's first sample.
                    if let url = pendingRecordURL, recorder == nil {
                        try? activateRecorder(formatDescription: format, url: url)
                    }
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

    /// Decode the audio socket and forward raw PCM. Only `raw` is forwarded; a
    /// disabled/errored or unsupported codec just leaves the mirror silent.
    private func consumeAudio(_ bytes: AsyncThrowingStream<Data, Error>) async {
        var audioDecoder = ScrcpyAudioStreamDecoder()
        var isRaw = false
        do {
            for try await chunk in bytes {
                if Task.isCancelled { break }
                for event in audioDecoder.consume(chunk) {
                    switch event {
                    case let .codec(codec, _):
                        isRaw = codec == .raw
                        if !isRaw { audioPCMContinuation?.finish() }
                    case let .packet(header, payload):
                        guard isRaw, !header.isConfig else { continue }
                        audioPCMContinuation?.yield(payload)
                        // Tee into the recording on the device's clock. recorderStarted
                        // flips on the first video key frame, so audio lands on the same
                        // timeline the writer session opened with.
                        if let recorder, recorderStarted {
                            let pts = CMTime(value: CMTimeValue(header.pts), timescale: 1_000_000)
                            recorder.appendAudio(payload, pts: pts)
                        }
                    }
                }
            }
        } catch {
            // Audio socket ended; the video mirror continues unaffected.
        }
        audioPCMContinuation?.finish()
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
