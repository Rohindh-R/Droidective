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

        // Lay the SwiftUI content out first so `.preferredContentSize` has
        // produced the real 520×height frame before we center. Otherwise
        // `positionInitially` centers the pre-layout placeholder width and the
        // palette lands off-center.
        hosting.view.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.view.fittingSize)

        positionInitially(panel)
        panel.makeKeyAndOrderFront(nil)

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.keepCentered() } }

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

    /// Keep the top edge anchored (so the search field doesn't jump as the
    /// results list grows) while staying horizontally centered on the current
    /// screen — the results list resizing the panel would otherwise leave a
    /// first-frame miscenter uncorrected on the X axis.
    private func keepCentered() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        var origin = panel.frame.origin
        let x = screen.visibleFrame.midX - panel.frame.width / 2
        let y = anchorMaxY - panel.frame.height
        if abs(origin.x - x) > 0.5 || abs(origin.y - y) > 0.5 {
            origin.x = x
            origin.y = y
            panel.setFrameOrigin(origin)
        }
    }
}
