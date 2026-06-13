import ADBKit
import AppKit
import SwiftUI

/// Capture the device screen, save it to ~/Downloads/Droidective, and show a
/// preview of the latest shot.
struct ScreenshotView: View {
    @Environment(AppState.self) private var state
    @State private var capturing = false
    @State private var lastCapture: URL?
    @State private var lastImage: NSImage?

    var body: some View {
        VStack(spacing: 14) {
            if let lastImage {
                Image(nsImage: lastImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480, maxHeight: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.separator, lineWidth: 1)
                    )
                    .onDrag {
                        // Drag the PNG file straight into Finder/Slack/etc.
                        lastCapture.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() }
                            ?? NSItemProvider()
                    }
                    .help("Drag to Finder, Slack, or anywhere that takes a file")
            } else {
                ContentUnavailableView(
                    "No screenshot yet",
                    systemImage: "camera",
                    description: Text("Captures are saved to ~/Downloads/Droidective.")
                )
                .frame(maxHeight: 300)
            }

            HStack(spacing: 10) {
                Button {
                    capture()
                } label: {
                    Label(capturing ? "Capturing…" : "Capture", systemImage: "camera.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(capturing || state.targetSerials.isEmpty)

                if let lastCapture {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([lastCapture])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .controlSize(.large)
                    Button {
                        // Copy the image itself, so ⌘V pastes into Slack,
                        // editors, etc. — not a file reference.
                        if let image = lastImage {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([image])
                            state.showToast(Toast(message: "Screenshot image copied", ok: true))
                        }
                    } label: {
                        Label("Copy", systemImage: "doc.on.clipboard")
                    }
                    .controlSize(.large)
                }
            }

            if state.targetSerials.isEmpty {
                Text("Connect a device to capture.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func capture() {
        capturing = true
        Task {
            await state.runScreenshot()
            if let entry = state.lastResults["screenshot"], entry.result.ok, let path = entry.result.revealPath {
                lastCapture = URL(fileURLWithPath: path)
                lastImage = NSImage(contentsOfFile: path)
            }
            capturing = false
        }
    }
}
