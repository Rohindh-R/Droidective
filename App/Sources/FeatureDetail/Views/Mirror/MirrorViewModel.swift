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
    /// Device video dimensions, once known — used to map taps to device coords.
    private(set) var videoSize: CGSize?
    /// Set when a screenshot is captured; the view presents the editor on it.
    var pendingScreenshot: NSImage?
    /// Set when a recording finishes; the view opens the video editor on it.
    var finishedRecording: URL?

    let renderer = MirrorRenderer()

    private let adb: AdbClient
    private let locator: ToolLocator
    private let serial: String
    private let captureFolder: URL

    private var session: MirrorSession?
    private var displayTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var recordingURL: URL?
    private var sendControl: (@Sendable (ScrcpyControlMessage) -> Void)?

    init(adb: AdbClient, locator: ToolLocator, serial: String, captureFolder: URL) {
        self.adb = adb
        self.locator = locator
        self.serial = serial
        self.captureFolder = captureFolder
    }

    func start() async {
        status = .connecting
        guard let server = await ScrcpyServerLocator.resolve(locator: locator) else {
            status = .failed("scrcpy isn’t installed. Run `brew install scrcpy`, then reopen.")
            return
        }
        // Control on (interactive mirror); audio off until phase 4. Cap the size
        // for smooth, low-latency display.
        let params = ScrcpyServerParams(
            scid: UInt32.random(in: 1 ... 0x7fff_ffff), control: true, maxSize: 1280)
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

    func toggleRecording() async {
        guard let session else { return }
        if isRecording {
            guard let url = recordingURL else { return }
            _ = try? await session.stopRecording(url: url)
            recordingURL = nil
            isRecording = false
            finishedRecording = url
        } else {
            let name = "mirror_\(Int(Date().timeIntervalSince1970)).mp4"
            let url = captureFolder.appendingPathComponent(name)
            do {
                try? FileManager.default.createDirectory(
                    at: captureFolder, withIntermediateDirectories: true)
                try await session.startRecording(to: url)
                recordingURL = url
                isRecording = true
            } catch {
                status = .failed("Couldn’t start recording: \(error.localizedDescription)")
            }
        }
    }
}
