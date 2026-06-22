import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Video Editor feature: open (or drop) any video and edit it. Fresh
/// recordings open the same editor automatically from Screen Record.
struct VideoEditorView: View {
    @Environment(AppState.self) private var state
    @State private var openedURL: URL?

    private static let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]

    var body: some View {
        Group {
            if let url = openedURL {
                VideoEditorPane(source: .file(url)) { openedURL = nil }
                    .id(url)
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                Image(systemName: "film").font(.system(size: 46)).foregroundStyle(.textMuted)
                Text("Edit a video").font(.title3.weight(.semibold))
                Text("Open a video to trim, rotate, crop, change speed, convert, and compress —\nor record one from Screen Record.")
                    .multilineTextAlignment(.center).foregroundStyle(.textMuted)
            }
            Button { openFile() } label: {
                Label("Open video…", systemImage: "folder").frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            if state.ffmpegStatus?.installed == false {
                Text("Editing needs ffmpeg — install it from Settings ▸ Tools.")
                    .font(.footnote).foregroundStyle(.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            openedURL = url
            return true
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.videoTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { openedURL = url }
    }
}
