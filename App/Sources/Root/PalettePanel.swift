import AppKit
import SwiftUI

/// A borderless panel that can still take key focus. Borderless `NSWindow`s
/// return `false` from `canBecomeKey`/`canBecomeMain` by default, which would
/// stop the palette's search field from receiving input; overriding them keeps
/// the panel chromeless yet focusable. A panel we own (vs. a SwiftUI `Window`
/// scene) can do this without colliding with SwiftUI's window constraints.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the ⌘K command palette as a borderless `NSPanel`. Borderless removes the
/// 32pt title-bar region a hidden-title-bar `Window` scene always reserves, so
/// the content sizes the panel exactly — flush at top and bottom. The panel
/// hosts `PaletteWindowView`, resizes to its content, keeps its top edge anchored
/// as results grow/shrink, and closes when it loses key (click-away) or on Esc.
@MainActor
final class PaletteController {
    static let shared = PaletteController()

    private var panel: KeyablePanel?
    private var anchorMaxY: CGFloat = 0
    private var resignObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?

    func show(appState: AppState) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let root = PaletteWindowView(onClose: { [weak self] in self?.close() })
            .environment(appState)
            .tint(.brandAccent)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]

        let panel = KeyablePanel(contentViewController: hosting)
        panel.styleMask = [.borderless]
        panel.identifier = NSUserInterfaceItemIdentifier("palette")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        positionInitially(panel)
        panel.makeKeyAndOrderFront(nil)

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.keepTopAnchored() } }

        self.panel = panel
    }

    func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resignObserver = nil
        resizeObserver = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    /// Center on screen, and remember the top edge so later resizes grow
    /// downward from there instead of drifting up off the bottom-left origin.
    private func positionInitially(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let frame = panel.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.midY - frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        anchorMaxY = panel.frame.maxY
    }

    private func keepTopAnchored() {
        guard let panel else { return }
        var frame = panel.frame
        if abs(frame.maxY - anchorMaxY) > 0.5 {
            frame.origin.y = anchorMaxY - frame.height
            panel.setFrameOrigin(frame.origin)
        }
    }
}
