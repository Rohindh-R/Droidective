import ADBKit
import AppKit
import SwiftUI

/// After a recording or screenshot is captured, ask what to do with it — shown
/// as a sheet with a preview and Edit / Save / Discard. Cancelling the sheet
/// discards, so nothing is orphaned. Shared by Screen Record and Mirror Screen.
private struct MediaDecisionView: View {
    let title: String
    let preview: NSImage?
    let loadingPreview: Bool
    let onEdit: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(title).font(.headline)

            Group {
                if let preview {
                    Image(nsImage: preview).resizable().scaledToFit()
                } else if loadingPreview {
                    ProgressView()
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: 360, height: 240)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Button(role: .destructive) { onDiscard() } label: {
                    Text("Discard").frame(maxWidth: .infinity)
                }
                Button { onSave() } label: { Text("Save").frame(maxWidth: .infinity) }
                Button { onEdit() } label: { Text("Edit").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Recording (video)

private struct RecordingDecisionModifier: ViewModifier {
    @Environment(AppState.self) private var state
    @Binding var url: URL?
    let onEdit: (URL) -> Void
    @State private var thumbnail: NSImage?
    @State private var loadingThumbnail = true

    func body(content: Content) -> some View {
        content.sheet(isPresented: presented, onDismiss: resetPreview) {
            if let url {
                MediaDecisionView(
                    title: "Recording finished",
                    preview: thumbnail,
                    loadingPreview: loadingThumbnail,
                    onEdit: { act(onEdit) },
                    onSave: { act(save) },
                    onDiscard: { act { try? FileManager.default.removeItem(at: $0) } })
                    .task(id: url) { await loadThumbnail(url) }
            }
        }
    }

    private func resetPreview() {
        thumbnail = nil
        loadingThumbnail = true
    }

    private func loadThumbnail(_ url: URL) async {
        loadingThumbnail = true
        let data = await VideoEditService(
            locator: state.env.client.locator, bundledPath: BundledTools.ffmpegPath()
        ).thumbnail(of: url)
        thumbnail = data.flatMap(NSImage.init(data:))
        loadingThumbnail = false
    }

    private var presented: Binding<Bool> {
        Binding(
            get: { url != nil },
            set: { shown in if !shown, let pending = url { url = nil; try? FileManager.default.removeItem(at: pending) } })
    }

    private func act(_ body: (URL) -> Void) {
        guard let pending = url else { return }
        url = nil
        body(pending)
    }

    private func save(_ pending: URL) {
        do {
            let dir = try ScreenCaptureService.ensureCaptureDir()
            let dest = dir.appendingPathComponent("recording_\(ScreenCaptureService.stamp()).mp4")
            try FileManager.default.moveItem(at: pending, to: dest)
            state.showToast(Toast(message: "Recording saved", ok: true, revealPath: dest.path))
        } catch {
            state.showToast(Toast(message: "Couldn’t save recording: \(error.localizedDescription)", ok: false))
        }
    }
}

// MARK: - Screenshot (image)

private struct ImageDecisionModifier: ViewModifier {
    @Environment(AppState.self) private var state
    @Binding var image: NSImage?
    let onEdit: (NSImage) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: presented) {
            if let image {
                MediaDecisionView(
                    title: "Screenshot captured",
                    preview: image,
                    loadingPreview: false,
                    onEdit: { act(onEdit) },
                    onSave: { act(save) },
                    onDiscard: { act { _ in } })
            }
        }
    }

    private var presented: Binding<Bool> {
        Binding(get: { image != nil }, set: { if !$0 { image = nil } })
    }

    private func act(_ body: (NSImage) -> Void) {
        guard let pending = image else { return }
        image = nil
        body(pending)
    }

    private func save(_ pending: NSImage) {
        guard let cgImage = pending.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            state.showToast(Toast(message: "Couldn’t encode the screenshot.", ok: false))
            return
        }
        do {
            let dir = try ScreenCaptureService.ensureCaptureDir()
            let dest = dir.appendingPathComponent("screenshot_\(ScreenCaptureService.stamp()).png")
            try png.write(to: dest)
            state.showToast(Toast(message: "Screenshot saved", ok: true, revealPath: dest.path))
        } catch {
            state.showToast(Toast(message: "Couldn’t save screenshot: \(error.localizedDescription)", ok: false))
        }
    }
}

extension View {
    /// Prompt Discard/Save/Edit (with a frame preview) for a finished recording.
    func recordingDecision(url: Binding<URL?>, onEdit: @escaping (URL) -> Void) -> some View {
        modifier(RecordingDecisionModifier(url: url, onEdit: onEdit))
    }

    /// Prompt Discard/Save/Edit (with a preview) for a captured screenshot.
    func imageDecision(image: Binding<NSImage?>, onEdit: @escaping (NSImage) -> Void) -> some View {
        modifier(ImageDecisionModifier(image: image, onEdit: onEdit))
    }
}
