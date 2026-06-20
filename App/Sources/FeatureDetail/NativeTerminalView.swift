import AppKit
import SwiftTerm
import SwiftUI

/// A real embedded shell (PTY-backed, via SwiftTerm), created once and shared
/// app-wide so the session and scrollback survive switching features and
/// minimizing the command bar. The login shell is started lazily the first
/// time the Terminal tab is shown.
@MainActor
final class TerminalSession {
    private var terminalView: LocalProcessTerminalView?

    /// The shared terminal view, starting the login shell on first use. The
    /// selected device serial is exported as `ANDROID_SERIAL` so `adb` targets
    /// it without `-s`.
    func view(serial: String?) -> LocalProcessTerminalView {
        if let terminalView { return terminalView }
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = Self.terminalFont(size: 12)
        terminalView = view

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        if let serial, !serial.isEmpty {
            environment["ANDROID_SERIAL"] = serial
        }
        view.startProcess(
            executable: environment["SHELL"] ?? "/bin/zsh",
            args: ["-l"],
            environment: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        return view
    }

    /// Terminate the shell and drop the view so the next `view(serial:)` starts
    /// a fresh session — used by the command bar's "kill terminal" button.
    func kill() {
        terminalView?.terminate()
        terminalView = nil
    }

    /// A fixed-width Nerd Font so prompt-theme glyphs (powerline separators,
    /// icons) render instead of missing-glyph boxes; falls back to the system
    /// monospace when no Nerd Font is installed.
    static func terminalFont(size: CGFloat) -> NSFont {
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies
        let family = families.first { $0.range(of: "Nerd Font Mono", options: .caseInsensitive) != nil }
            ?? families.first { $0.range(of: "Nerd Font", options: .caseInsensitive) != nil }
            ?? families.first { $0.range(of: "Nerd", options: .caseInsensitive) != nil }
        if let family, let font = manager.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// SwiftUI host for the shared terminal. SwiftUI tears down and recreates the
/// representable when the Terminal tab is hidden/reshown; returning the shared
/// view directly let SwiftUI reset it, spawning a fresh-looking shell. Instead
/// we hand SwiftUI a fresh container each time and re-parent the one live
/// terminal into it, so the PTY session and scrollback truly persist.
struct NativeTerminalView: NSViewRepresentable {
    let session: TerminalSession
    let serial: String?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        mount(in: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        mount(in: nsView)
    }

    private func mount(in container: NSView) {
        let terminal = session.view(serial: serial)
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
