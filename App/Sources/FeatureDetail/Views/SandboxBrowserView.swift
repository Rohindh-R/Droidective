import ADBKit
import SwiftUI

/// Browse and pull an app's private files via run-as (debug builds only).
/// `packageId` overrides the global selected bundle, so the Apps view can hand
/// it the selected app to explore any debuggable app's sandbox.
struct SandboxBrowserView: View {
    @Environment(AppState.self) private var state
    var packageId: String?
    @State private var pathComponents: [String] = []
    @State private var entries: [FsEntry]?
    @State private var debuggable = true

    /// The package to browse — the explicit one, else the selected bundle.
    private var pkg: String? { packageId ?? state.selectedBundle?.packageId }

    private var currentPath: String {
        guard let pkg else { return "/" }
        let root = "/data/data/\(pkg)"
        return pathComponents.isEmpty ? root : root + "/" + pathComponents.joined(separator: "/")
    }

    var body: some View {
        Group {
            if pkg == nil {
                ContentUnavailableView(
                    "No bundle selected", systemImage: "folder",
                    description: Text("Select a bundle to browse its sandbox.")
                )
            } else if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to browse files.")
                )
            } else if !debuggable {
                ContentUnavailableView(
                    "App not debuggable", systemImage: "lock",
                    description: Text("run-as only works on debug builds. Install a debug build to browse its sandbox.")
                )
            } else {
                browser
            }
        }
        .onChange(of: "\(pkg ?? "")|\(state.targetSerials.first ?? "")") {
            pathComponents = []
        }
        // One structured loader keyed on package+device+path: every navigation
        // cancels the previous load, so entries always match the breadcrumb.
        .task(id: "\(pkg ?? "")|\(state.targetSerials.first ?? "")|\(currentPath)") {
            await load()
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button("Home") {
                        pathComponents = []
                    }
                    .buttonStyle(.link)
                    ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                        Text("/").foregroundStyle(.secondary)
                        Button(component) {
                            pathComponents = Array(pathComponents.prefix(index + 1))
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(8)
            }
            Divider()

            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("Empty directory", systemImage: "folder")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !pathComponents.isEmpty {
                            Button {
                                pathComponents.removeLast()
                            } label: {
                                Label("..", systemImage: "arrow.turn.up.left")
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func row(_ entry: FsEntry) -> some View {
        HStack {
            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDir ? .blue : .secondary)
            if entry.isDir {
                Button(entry.name) {
                    pathComponents.append(entry.name)
                }
                .buttonStyle(.plain)
            } else {
                Text(entry.name)
            }
            Spacer()
            if !entry.isDir {
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    pull(entry)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .help("Pull to ~/Downloads/Droidective")
            }
        }
    }

    private func load() async {
        entries = nil
        debuggable = true
        guard let serial = state.targetSerials.first, let pkg else { return }
        let result = await CommandLog.userInitiated(feature: "sandbox-browser") {
            try? await state.env.engine.inspection.sandboxList(
                serial: serial, packageId: pkg, dir: currentPath
            )
        }
        guard !Task.isCancelled else { return }
        guard let result else {
            entries = []
            return
        }
        debuggable = result.debuggable
        entries = result.entries
    }

    private func pull(_ entry: FsEntry) {
        guard let serial = state.targetSerials.first, let pkg else { return }
        guard let dest = state.askSaveLocation(suggestedName: entry.name) else { return }
        let filePath = currentPath + "/" + entry.name
        Task {
            await CommandLog.userInitiated(feature: "sandbox-browser") {
                do {
                    let saved = try await state.withOperation("Pulling \(entry.name)…") {
                        try await state.env.engine.inspection.sandboxPull(
                            serial: serial, packageId: pkg, filePath: filePath, to: dest
                        )
                    }
                    state.showToast(Toast(message: "Pulled \(entry.name)", ok: true, revealPath: saved.path))
                } catch {
                    state.showToast(Toast(message: error.localizedDescription, ok: false))
                }
            }
        }
    }
}
