import ADBKit
import AVFoundation
import SwiftUI

/// Owns the `AVSampleBufferDisplayLayer` the session feeds compressed frames to.
/// Lives on the main actor since it drives a layer.
@MainActor final class MirrorRenderer {
    let displayLayer = AVSampleBufferDisplayLayer()

    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    init() {
        displayLayer.videoGravity = .resizeAspect
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // A failed renderer won't recover until flushed; the next key frame re-primes it.
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
    }

    func clear() {
        renderer.flush()
    }
}

/// An NSView that keeps the display layer sized to its bounds and forwards mouse
/// and keyboard input as normalized callbacks. Flipped so coordinates share the
/// device's top-left origin.
final class MirrorLayerNSView: NSView {
    var onTouch: ((ScrcpyControlMessage.TouchAction, CGPoint) -> Void)?
    var onKeycode: ((UInt32, ScrcpyControlMessage.KeyAction) -> Void)?
    var onText: ((String) -> Void)?
    var videoSize: CGSize?

    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    // MARK: - Mouse → touch

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let point = normalized(event) { onTouch?(.down, point) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let point = normalized(event) { onTouch?(.move, point) }
    }

    override func mouseUp(with event: NSEvent) {
        if let point = normalized(event) { onTouch?(.up, point) }
    }

    /// The aspect-fit rect the video occupies inside the (letterboxed) bounds.
    private func videoRect() -> CGRect? {
        guard let size = videoSize, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let viewAspect = bounds.width / bounds.height
        let videoAspect = size.width / size.height
        if videoAspect > viewAspect {
            let height = bounds.width / videoAspect
            return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        }
        let width = bounds.height * videoAspect
        return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
    }

    private func normalized(_ event: NSEvent) -> CGPoint? {
        guard let rect = videoRect() else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        return CGPoint(x: (clampedX - rect.minX) / rect.width, y: (clampedY - rect.minY) / rect.height)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if let keycode = Self.androidKeycode(for: event.keyCode) {
            onKeycode?(keycode, .down)
            return
        }
        guard !event.modifierFlags.contains(.command) else { return }  // let ⌘ shortcuts pass
        if let text = event.characters, !text.isEmpty { onText?(text) }
    }

    override func keyUp(with event: NSEvent) {
        if let keycode = Self.androidKeycode(for: event.keyCode) { onKeycode?(keycode, .up) }
    }

    /// Map the macOS keys that have no text representation to Android keycodes.
    private static func androidKeycode(for macKeyCode: UInt16) -> UInt32? {
        switch macKeyCode {
        case 36, 76: 66   // Return / Keypad Enter → ENTER
        case 51: 67       // Delete → DEL (backspace)
        case 117: 112     // Forward Delete → FORWARD_DEL
        case 53: 4        // Escape → BACK
        case 48: 61       // Tab → TAB
        case 123: 21      // ← LEFT
        case 124: 22      // → RIGHT
        case 125: 20      // ↓ DOWN
        case 126: 19      // ↑ UP
        default: nil
        }
    }
}

/// SwiftUI bridge for the live mirror surface.
struct MirrorVideoView: NSViewRepresentable {
    let renderer: MirrorRenderer
    var videoSize: CGSize?
    var onTouch: ((ScrcpyControlMessage.TouchAction, CGPoint) -> Void)?
    var onKeycode: ((UInt32, ScrcpyControlMessage.KeyAction) -> Void)?
    var onText: ((String) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = MirrorLayerNSView(displayLayer: renderer.displayLayer)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MirrorLayerNSView else { return }
        apply(to: view)
    }

    private func apply(to view: MirrorLayerNSView) {
        view.videoSize = videoSize
        view.onTouch = onTouch
        view.onKeycode = onKeycode
        view.onText = onText
    }
}
