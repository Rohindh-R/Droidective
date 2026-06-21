import ADBKit
import AppKit
import SwiftUI

/// Capture the device screen and open it in an editor for markup, crop, and
/// zoom — saved only on demand. Captures triggered from the sidebar ⏎, the
/// global hotkey, or the menu bar instead save straight to the capture folder.
struct ScreenshotView: View {
    @Environment(AppState.self) private var state
    @State private var image: NSImage?
    @State private var capturing = false
    @AppStorage("screenshotDelay") private var captureDelay = 0

    var body: some View {
        Group {
            if let image {
                ScreenshotEditorView(image: image) { self.image = nil }
                    .id(ObjectIdentifier(image))
            } else {
                captureControls
            }
        }
    }

    private var captureControls: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: "camera")
                    .font(.system(size: 46))
                    .foregroundStyle(.textMuted)
                Text("Capture a screenshot")
                    .font(.title3.weight(.semibold))
                Text("Grab the device screen, then mark it up, crop, and save —\nnothing is written to disk until you choose to.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.textMuted)
            }

            HStack(spacing: 16) {
                Picker("Delay", selection: $captureDelay) {
                    Text("No delay").tag(0)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                }
                .pickerStyle(.menu)
                .fixedSize()

                Button {
                    capture()
                } label: {
                    Label(capturing ? "Capturing…" : "Capture", systemImage: "camera.fill")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(capturing || state.targetSerials.isEmpty)
            }
            .fixedSize(horizontal: true, vertical: false)

            if state.targetSerials.isEmpty {
                Text("Connect a device to capture.")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func capture() {
        capturing = true
        Task {
            if let shot = await state.captureForEditor(delaySeconds: captureDelay) {
                image = shot
            }
            capturing = false
        }
    }
}
