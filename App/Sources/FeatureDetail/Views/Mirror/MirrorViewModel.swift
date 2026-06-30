import ADBKit
import AppKit
import Foundation
import Observation

/// Drives one in-window mirror: owns the `MirrorSession`, pumps decoded display
/// samples into the renderer on the main actor, forwards input as control
/// messages, and exposes the screenshot / record actions the toolbar calls.
@MainActor
@Observable
final class MirrorViewModel {
    enum Status: Equatable {
        case connecting
        case streaming
        case failed(String)
        case stopped
    }

    private(set) var status: Status = .connecting
    private(set) var isRecording = false
    private(set) var isPaused = false
    private var recordBusy = false
    /// Device video dimensions, once known — used to map taps to device coords.
    private(set) var videoSize: CGSize?
    /// Set when a screenshot is captured; the view shows the Discard/Save/Edit prompt.
    var pendingScreenshot: NSImage?
    /// Set when "Edit" is chosen for a screenshot; the view opens the editor on it.
    var editingScreenshot: NSImage?
    /// Set when the user picks "Edit" from the post-recording prompt; the view
    /// opens the video editor on it.
    var finishedRecording: URL?
    /// Set when a recording stops; the view shows the Discard/Save/Edit prompt.
    var pendingRecording: URL?
    /// Set when recording fails to start; the view surfaces it as a toast.
    var recordingError: String?

    let renderer = MirrorRenderer()

    private let adb: AdbClient
    private let locator: ToolLocator
    private let serial: String

    private var session: MirrorSession?
    private var displayTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    /// Built off the main thread on the first audio packet — see `start()`. nil
    /// until then so audio-less devices never touch Core Audio.
    private var audioPlayer: MirrorAudioPlayer?
    /// The bundled scrcpy server, resolved at start — reused to spin up a
    /// recording session.
    private var server: ScrcpyServerInfo?
    /// Recording uses its OWN scrcpy session so it captures from a fresh key
    /// frame; the display session keeps mirroring/controlling meanwhile. (Starting
    /// to record on the live session can't get a key frame mid-stream — the
    /// encoder emits them rarely.)
    private var screenRecorder: ScreenRecorder?
    private var sendControl: (@Sendable (ScrcpyControlMessage) -> Void)?
    /// Whether to request device audio. Cleared after one failed start so the
    /// mirror reconnects video-only on devices that can't capture audio (most
    /// emulators) — scrcpy aborts the whole session, video included, when its
    /// audio encoder can't start. See `MirrorAudioFallback`.
    private var requestAudio = true
    /// Set once video frames begin flowing; gates the video-only fallback so a
    /// session that streamed and later stopped isn't silently restarted.
    private var didStream = false

    init(adb: AdbClient, locator: ToolLocator, serial: String) {
        self.adb = adb
        self.locator = locator
        self.serial = serial
    }

    func start() async {
        status = .connecting
        didStream = false
        // Prefer the bundled server (self-contained); fall back to an installed
        // scrcpy only if the bundled resource is somehow missing.
        let server: ScrcpyServerInfo?
        if let bundled = BundledTools.scrcpyServer() {
            server = bundled
        } else {
            server = await ScrcpyServerLocator.resolve(locator: locator)
        }
        guard let server else {
            status = .failed("Couldn’t find the scrcpy server.")
            return
        }
        self.server = server
        // Interactive mirror: control on, audio when the device can supply it.
        // Cap the size for smooth, low-latency display. Recording started
        // mid-stream forces a fresh key frame via RESET_VIDEO (see
        // MirrorSession.startRecording).
        let params = ScrcpyServerParams(
            scid: UInt32.random(in: 1 ... 0x7fff_ffff),
            audio: requestAudio, control: true, maxSize: 1280)
        let config = MirrorTransport.Configuration(
            serial: serial, params: params,
            serverVersion: server.version, localJarPath: server.jarPath)
        let session = MirrorSession(adb: adb, config: config)
        self.session = session

        let stream = await session.start()

        let clipboards = await session.incomingClipboards()
        clipboardTask = Task { @MainActor in
            guard let clipboards else { return }
            for await text in clipboards {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        let audio = await session.audioPCM()
        audioTask = Task { [weak self] in
            guard let audio else { return }
            // Build and start the AVAudioEngine graph OFF the main thread. Creating
            // AVAudioPlayerNode / attaching nodes makes a synchronous XPC round-trip
            // to the audio-component registrar that can block for seconds on first
            // use, freezing the UI (Sentry DROIDECTIVE-MAC-5). Built lazily on the
            // first packet, so audio-less devices (Android < 11) never reach here.
            // MirrorAudioPlayer is @unchecked Sendable and only ever touched here.
            let player = await Task.detached(priority: .userInitiated) { () -> MirrorAudioPlayer? in
                let player = MirrorAudioPlayer()
                do { try player.start() } catch { return nil }
                return player
            }.value
            guard let player else { return }
            await MainActor.run { [weak self] in self?.audioPlayer = player }
            defer { player.stop() }
            for await pcm in audio {
                player.enqueue(pcmS16LE: pcm)
            }
        }

        displayTask = Task { @MainActor [weak self] in
            do {
                for try await sample in stream {
                    guard let self else { break }
                    self.renderer.enqueue(sample.sampleBuffer, width: sample.width, height: sample.height)
                    // Track the live frame size so taps map correctly and the aspect
                    // rect stays right across rotation, not only at the first frame.
                    if sample.width > 0, sample.height > 0 {
                        let size = CGSize(width: sample.width, height: sample.height)
                        if self.videoSize != size { self.videoSize = size }
                    }
                    if self.status == .connecting {
                        self.status = .streaming
                        self.didStream = true
                        // The transport (incl. the control socket) is connected
                        // once frames flow — fetch the control sender now, not
                        // right after start() when it isn't wired yet.
                        self.sendControl = await self.session?.controlSender()
                    }
                }
                await self?.sessionEnded(failure: nil)
            } catch is CancellationError {
                // expected on stop()
            } catch {
                await self?.sessionEnded(failure: error.localizedDescription)
            }
        }
    }

    /// The display stream ended (the device closed it, or it errored — not a
    /// user-initiated stop, which cancels the task). If audio was requested and
    /// no frame ever streamed, scrcpy likely aborted the session because the
    /// device couldn't capture audio, so reconnect once video-only. Otherwise
    /// surface the terminal state.
    private func sessionEnded(failure: String?) async {
        if MirrorAudioFallback.shouldRetryWithoutAudio(
            audioRequested: requestAudio, everStreamed: didStream) {
            requestAudio = false
            await stop()
            await start()
            return
        }
        status = failure.map(Status.failed) ?? .stopped
    }

    func stop() async {
        displayTask?.cancel()
        displayTask = nil
        clipboardTask?.cancel()
        clipboardTask = nil
        audioTask?.cancel()
        audioTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        if let recorder = screenRecorder { await recorder.abort() }
        screenRecorder = nil
        await session?.stop()
        session = nil
        sendControl = nil
        isRecording = false
        renderer.clear()
    }

    // MARK: - Input

    /// Forward a touch at a normalized (top-left origin) point in the video.
    func touch(_ action: ScrcpyControlMessage.TouchAction, at point: CGPoint) {
        guard let size = videoSize, let send = sendControl else { return }
        let x = Int32((point.x * size.width).rounded())
        let y = Int32((point.y * size.height).rounded())
        send(.injectTouch(
            action: action, pointerID: 0, x: x, y: y,
            screenWidth: UInt16(size.width), screenHeight: UInt16(size.height),
            pressure: action == .up ? 0 : 1, actionButton: 0, buttons: 0))
    }

    func key(_ keycode: UInt32, _ action: ScrcpyControlMessage.KeyAction) {
        sendControl?(.injectKeycode(action: action, keycode: keycode, repeatCount: 0, metaState: 0))
    }

    /// Tap a hardware/navigation key (down then up). BACK=4, HOME=3, APP_SWITCH=187.
    func tapKey(_ keycode: UInt32) {
        key(keycode, .down)
        key(keycode, .up)
    }

    func text(_ string: String) {
        guard !string.isEmpty else { return }
        sendControl?(.injectText(string))
    }

    /// ⌘V — push the Mac clipboard to the device and paste it.
    func pasteToDevice() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        sendControl?(.setClipboard(sequence: 0, paste: true, text: text))
    }

    /// ⌘C / ⌘X — ask the device to copy/cut its selection; it syncs back to the Mac.
    func copyFromDevice(cut: Bool) {
        sendControl?(.getClipboard(copyKey: cut ? .cut : .copy))
    }

    // MARK: - Capture

    func takeScreenshot() async {
        guard let snapshot = await session?.snapshot() else { return }
        pendingScreenshot = MirrorImage.nsImage(from: snapshot.imageBuffer)
    }

    func startRecording() async {
        guard !isRecording, let server else { return }
        let recorder = ScreenRecorder(
            client: adb, server: server, ffmpegPath: BundledTools.ffmpegPath())
        do {
            try await recorder.start(
                serial: serial, options: ScreenRecordOptions(maxSize: 1280, captureAudio: true))
            screenRecorder = recorder
            isRecording = true
            isPaused = false
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard let recorder = screenRecorder else { return }
        screenRecorder = nil
        isRecording = false
        isPaused = false
        // Stopping returns the finished temp file; the view prompts discard/save/edit.
        if let url = try? await recorder.stop() { pendingRecording = url }
    }

    /// Stop recording for a "Stop & save" leave and return the finished file
    /// without raising the Discard/Save/Edit prompt — the caller saves it.
    func finishRecordingForLeave() async -> URL? {
        guard let recorder = screenRecorder else { return nil }
        screenRecorder = nil
        isRecording = false
        isPaused = false
        return try? await recorder.stop()
    }

    func pauseRecording() async {
        guard let recorder = screenRecorder, !recordBusy, !isPaused else { return }
        recordBusy = true
        await recorder.pause()
        isPaused = true
        recordBusy = false
    }

    func resumeRecording() async {
        guard let recorder = screenRecorder, !recordBusy, isPaused else { return }
        recordBusy = true
        do {
            try await recorder.resume()
            isPaused = false
        } catch {
            recordingError = error.localizedDescription
        }
        recordBusy = false
    }
}
