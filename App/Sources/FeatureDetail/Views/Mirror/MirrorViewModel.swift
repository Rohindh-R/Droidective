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
    /// The device's media volume as a 0...1 fraction for the slider. Synced from
    /// the device on connect and after each change.
    private(set) var volume: Double = 0
    /// Current/last device volume steps and the stream's max (e.g. 0...15).
    private var volumeStep = 0
    private var maxVolumeStep = 15
    private var lastVolumeStep = 0
    private var volumeBusy = false
    /// Muted == device volume at zero.
    var isMuted: Bool { volumeStep == 0 }
    /// Speaker glyph reflecting the current device volume level.
    var volumeIcon: String {
        switch volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
    /// Device video dimensions, once known — used to map taps to device coords.
    private(set) var videoSize: CGSize?
    /// Set when a screenshot is captured; the view presents the editor on it.
    var pendingScreenshot: NSImage?
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
    private let audioPlayer = MirrorAudioPlayer()
    /// The bundled scrcpy server, resolved at start — reused to spin up a
    /// recording session.
    private var server: ScrcpyServerInfo?
    /// Recording uses its OWN scrcpy session so it captures from a fresh key
    /// frame; the display session keeps mirroring/controlling meanwhile. (Starting
    /// to record on the live session can't get a key frame mid-stream — the
    /// encoder emits them rarely.)
    private var screenRecorder: ScreenRecorder?
    private var sendControl: (@Sendable (ScrcpyControlMessage) -> Void)?

    init(adb: AdbClient, locator: ToolLocator, serial: String) {
        self.adb = adb
        self.locator = locator
        self.serial = serial
    }

    func start() async {
        status = .connecting
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
        // Interactive mirror: control + audio on. Cap the size for smooth,
        // low-latency display. Recording started mid-stream forces a fresh key
        // frame via RESET_VIDEO (see MirrorSession.startRecording).
        let params = ScrcpyServerParams(
            scid: UInt32.random(in: 1 ... 0x7fff_ffff),
            audio: true, control: true, maxSize: 1280)
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
        audioTask = Task { @MainActor [weak self] in
            guard let self, let audio else { return }
            var started = false
            for await pcm in audio {
                // Start the engine lazily on the first packet — devices without
                // audio (Android < 11) never get here, so we don't touch Core Audio.
                if !started {
                    do { try self.audioPlayer.start() } catch { return }
                    started = true
                }
                self.audioPlayer.enqueue(pcmS16LE: pcm)
            }
        }

        displayTask = Task { @MainActor [weak self] in
            do {
                for try await sample in stream {
                    guard let self else { break }
                    self.renderer.enqueue(sample.sampleBuffer)
                    if self.status == .connecting {
                        self.status = .streaming
                        // The transport (incl. the control socket) is connected
                        // once frames flow — fetch the control sender now, not
                        // right after start() when it isn't wired yet.
                        self.sendControl = await self.session?.controlSender()
                        if let dimensions = await self.session?.currentDimensions() {
                            self.videoSize = CGSize(width: dimensions.width, height: dimensions.height)
                        }
                        await self.refreshDeviceVolume()
                    }
                }
                self?.status = .stopped
            } catch is CancellationError {
                // expected on stop()
            } catch {
                self?.status = .failed(error.localizedDescription)
            }
        }
    }

    func stop() async {
        displayTask?.cancel()
        displayTask = nil
        clipboardTask?.cancel()
        clipboardTask = nil
        audioTask?.cancel()
        audioTask = nil
        audioPlayer.stop()
        if let recorder = screenRecorder { await recorder.abort() }
        screenRecorder = nil
        await session?.stop()
        session = nil
        sendControl = nil
        isRecording = false
        renderer.clear()
    }

    /// Move the slider locally while dragging (no device traffic until release).
    func previewVolume(_ value: Double) {
        volume = max(0, min(1, value))
    }

    /// Apply the slider's value to the device once the drag ends.
    func commitVolume(_ value: Double) {
        let target = Int((max(0, min(1, value)) * Double(maxVolumeStep)).rounded())
        Task { await applyVolumeStep(target) }
    }

    /// Toggle mute: drop the device volume to zero, or restore the last level.
    func toggleMute() {
        let target = volumeStep > 0 ? 0 : (lastVolumeStep > 0 ? lastVolumeStep : maxVolumeStep)
        Task { await applyVolumeStep(target) }
    }

    /// Drive the device volume to `target` by injecting VOLUME_UP/DOWN presses,
    /// then re-reading the device to correct for any presses it dropped or spent
    /// showing the volume HUD (up to two rounds). The slider always ends on the
    /// device's true level.
    private func applyVolumeStep(_ target: Int) async {
        guard !volumeBusy else { return }
        volumeBusy = true
        defer { volumeBusy = false }
        let clamped = max(0, min(maxVolumeStep, target))
        for _ in 0 ..< 2 {
            let delta = clamped - volumeStep
            guard delta != 0 else { break }
            let keycode: UInt32 = delta > 0 ? 24 : 25  // VOLUME_UP / VOLUME_DOWN
            for _ in 0 ..< abs(delta) {
                tapKey(keycode)
                try? await Task.sleep(for: .milliseconds(90))
            }
            await refreshDeviceVolume()
        }
        if volumeStep > 0 { lastVolumeStep = volumeStep }
    }

    /// Read the device's current media volume + range to position the slider.
    private func refreshDeviceVolume() async {
        guard let output = try? await adb.run(
            on: serial, ["shell", "cmd", "media_session", "volume", "--stream", "3", "--get"]),
            let valueRange = output.stdout.range(of: "volume is ") else { return }
        let level = Int(output.stdout[valueRange.upperBound...].prefix { $0.isNumber }) ?? 0
        if let dotRange = output.stdout.range(of: "..") {
            maxVolumeStep = max(1, Int(output.stdout[dotRange.upperBound...].prefix { $0.isNumber }) ?? 15)
        }
        volumeStep = min(level, maxVolumeStep)
        if volumeStep > 0 { lastVolumeStep = volumeStep }
        volume = Double(volumeStep) / Double(maxVolumeStep)
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
