import ADBKit
import SwiftUI

/// Browse the device's shared storage with multi-select, copy/cut/paste,
/// delete, new folder, pull-to-Mac, and per-item Get Info. Long operations
/// surface in the progress strip.
struct FileExplorerView: View {
    @Environment(AppState.self) private var state
    @State private var pathComponents: [String] = []
    @State private var entries: [FsEntry]?
    @State private var reloadToken = 0
    @State private var selection: Set<String> = []

    /// Device-side clipboard: source paths plus whether to move (cut).
    @State private var clipboard: (paths: [String], isCut: Bool)?
    @State private var confirmingDelete: [FsEntry] = []
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var infoTarget: FsEntry?
    @State private var infoDetails: FileExplorerService.FileInfo?
    @FocusState private var listFocused: Bool

    private var currentPath: String {
        pathComponents.isEmpty
            ? FileExplorerService.defaultRoot
            : FileExplorerService.defaultRoot + "/" + pathComponents.joined(separator: "/")
    }

    private var selectedEntries: [FsEntry] {
        (entries ?? []).filter { selection.contains($0.id) }
    }

    var body: some View {
        Group {
            if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to browse its storage.")
                )
            } else {
                browser
            }
        }
        .onChange(of: state.targetSerials.first ?? "") { pathComponents = [] }
        .onChange(of: currentPath) { selection = [] }
        .task(id: "\(state.targetSerials.first ?? "")|\(currentPath)|\(reloadToken)") {
            await load()
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !selection.isEmpty {
                selectionBar
                Divider()
            }

            if let entries {
                if entries.isEmpty {
                    // Must fill the remaining space — an unexpanded empty
                    // state lets the whole VStack center mid-window.
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    listView(entries)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            confirmingDelete.count == 1
                ? "Delete \(confirmingDelete.first?.name ?? "")? This can't be undone."
                : "Delete \(confirmingDelete.count) items? This can't be undone.",
            isPresented: Binding(get: { !confirmingDelete.isEmpty }, set: { if !$0 { confirmingDelete = [] } })
        ) {
            Button("Delete", role: .destructive) {
                delete(confirmingDelete)
                confirmingDelete = []
            }
            Button("Cancel", role: .cancel) { confirmingDelete = [] }
        }
        .sheet(item: $infoTarget) { entry in
            fileInfoSheet(entry)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button("sdcard") { pathComponents = [] }
                        .buttonStyle(.link)
                    ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                        Text("/").foregroundStyle(.secondary)
                        Button(component) {
                            pathComponents = Array(pathComponents.prefix(index + 1))
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Spacer()

            if let clipboard {
                Button {
                    paste()
                } label: {
                    Label(
                        clipboard.paths.count == 1
                            ? "Paste \((clipboard.paths[0] as NSString).lastPathComponent)"
                            : "Paste \(clipboard.paths.count) items",
                        systemImage: clipboard.isCut ? "scissors" : "doc.on.doc"
                    )
                }
                .controlSize(.small)
                Button {
                    self.clipboard = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Clear clipboard")
            }

            Button(selection.count == (entries?.count ?? 0) && !selection.isEmpty ? "Deselect All" : "Select All") {
                if selection.count == (entries?.count ?? 0) {
                    selection = []
                } else {
                    selection = Set((entries ?? []).map(\.id))
                }
            }
            .controlSize(.small)
            .disabled((entries ?? []).isEmpty)

            Button {
                newFolderName = ""
                showNewFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .controlSize(.small)

            Button {
                reloadToken += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Refresh")
        }
        .padding(8)
    }

    /// Bulk actions for the current selection.
    private var selectionBar: some View {
        HStack(spacing: 8) {
            Text("\(selection.count) selected")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy") { clipboard = (selectedEntries.map(path(for:)), false) }
            Button("Cut") { clipboard = (selectedEntries.map(path(for:)), true) }
            Button("Pull to Mac") { pull(selectedEntries) }
            Button("Delete", role: .destructive) { confirmingDelete = selectedEntries }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4))
    }

    private func listView(_ entries: [FsEntry]) -> some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                Color.clear
                    .frame(height: 0)
                    .id("fe-top")
                    .listRowSeparator(.hidden)
                if !pathComponents.isEmpty {
                    Button {
                        pathComponents.removeLast()
                    } label: {
                        Label("..", systemImage: "arrow.turn.up.left")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(entries) { entry in
                    row(entry).tag(entry.id)
                }
            }
            .focused($listFocused)
            // Explicit scroll reset on navigation — recreating the List via
            // .id() left the new list mid-scroll under the safe-area inset.
            .onChange(of: currentPath) {
                proxy.scrollTo("fe-top", anchor: .top)
            }
            .onAppear {
                proxy.scrollTo("fe-top", anchor: .top)
                listFocused = true
            }
        }
        // ⌘C / ⌘X / ⌘V via the standard Edit menu plumbing.
        .onCopyCommand { copySelection(isCut: false) }
        .onCutCommand { copySelection(isCut: true) }
        .onPasteCommand(of: ["public.file-url", "public.utf8-plain-text"]) { providers in
            handlePaste(providers)
        }
        // ⏎ opens the selected folder.
        .onKeyPress(.return) {
            if let only = selectedEntries.first, selectedEntries.count == 1, only.isDir {
                pathComponents.append(only.name)
                return .handled
            }
            return .ignored
        }
        // Drag files in from Finder to push them to the device.
        .dropDestination(for: URL.self) { urls, _ in
            push(urls)
            return true
        }
    }

    /// ⌘C/⌘X: remember the device paths internally and put a text marker on
    /// the system pasteboard so ⌘V routes back to us.
    private func copySelection(isCut: Bool) -> [NSItemProvider] {
        let entries = selectedEntries
        guard !entries.isEmpty else { return [] }
        clipboard = (entries.map(path(for:)), isCut)
        let marker = entries.map(path(for:)).joined(separator: "\n")
        return [NSItemProvider(object: marker as NSString)]
    }

    /// ⌘V: Finder file URLs are pushed to the device; otherwise an internal
    /// copy/cut is pasted device-side. Reads file URLs straight off the
    /// general pasteboard — simpler and SDK-stable vs async NSItemProvider.
    private func handlePaste(_ providers: [NSItemProvider]) {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let fileURLs = urls.filter(\.isFileURL)
        if !fileURLs.isEmpty {
            push(fileURLs)
        } else if clipboard != nil {
            paste()
        }
    }

    /// adb push Mac files into the current device folder.
    private func push(_ urls: [URL]) {
        guard !urls.isEmpty, let serial = state.targetSerials.first else { return }
        let destination = currentPath
        let explorer = state.env.engine.fileExplorer
        Task {
            await CommandLog.userInitiated(feature: "file-explorer") {
                for url in urls {
                    let result = await state.withOperation("Pushing \(url.lastPathComponent)…") {
                        (try? await explorer.push(serial: serial, localPath: url.path, toDir: destination))
                            ?? FeatureResult(ok: false, message: "adb not found")
                    }
                    if !result.ok {
                        state.showToast(Toast(message: result.message, ok: false))
                        return
                    }
                }
                state.showToast(Toast(
                    message: urls.count == 1 ? "Pushed \(urls[0].lastPathComponent)" : "Pushed \(urls.count) files",
                    ok: true
                ))
            }
            reloadToken += 1
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
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Get Info") { showInfo(entry) }
            Divider()
            Button("Copy") { clipboard = (targets(for: entry).map(path(for:)), false) }
            Button("Cut") { clipboard = (targets(for: entry).map(path(for:)), true) }
            Button("Pull to Mac") { pull(targets(for: entry)) }
            Divider()
            Button("Delete", role: .destructive) { confirmingDelete = targets(for: entry) }
        }
    }

    /// Right-clicking inside a multi-selection acts on the whole selection.
    private func targets(for entry: FsEntry) -> [FsEntry] {
        selection.contains(entry.id) && selection.count > 1 ? selectedEntries : [entry]
    }

    // MARK: - Get Info

    private func fileInfoSheet(_ entry: FsEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: entry.isDir ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDir ? .blue : .secondary)
                Text(entry.name).font(.headline)
                Spacer()
                Button("Done") { infoTarget = nil }
            }
            .padding(12)
            Divider()

            Form {
                if let details = infoDetails {
                    LabeledContent("Type", value: details.type)
                    if let size = details.sizeBytes {
                        LabeledContent("Size", value: ByteCountFormatter.string(
                            fromByteCount: Int64(size), countStyle: .file
                        ))
                    }
                    LabeledContent("Owner", value: details.owner)
                    LabeledContent("Permissions") {
                        Text(details.permissions).monospaced()
                    }
                    LabeledContent("Modified", value: details.modified)
                    LabeledContent("Metadata Changed", value: details.changed)
                    LabeledContent("Path") {
                        Text(path(for: entry)).textSelection(.enabled)
                    }
                    Text("Android doesn't record file creation time — Modified is the closest signal.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading file info…").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 420, height: 330)
        .task(id: entry.id) {
            infoDetails = nil
            guard let serial = state.targetSerials.first else { return }
            infoDetails = await CommandLog.userInitiated(feature: "file-explorer") {
                try? await state.env.engine.fileExplorer.info(serial: serial, path: path(for: entry))
            }
        }
    }

    private func showInfo(_ entry: FsEntry) {
        infoDetails = nil
        infoTarget = entry
    }

    // MARK: - Operations

    private func path(for entry: FsEntry) -> String {
        currentPath + "/" + entry.name
    }

    private func load() async {
        entries = nil
        guard let serial = state.targetSerials.first else { return }
        let result = await CommandLog.userInitiated(feature: "file-explorer") {
            try? await state.env.engine.fileExplorer.list(serial: serial, dir: currentPath)
        }
        guard !Task.isCancelled else { return }
        entries = result ?? []
        selection = selection.intersection(Set((entries ?? []).map(\.id)))
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let serial = state.targetSerials.first else { return }
        let target = currentPath + "/" + name
        let explorer = state.env.engine.fileExplorer
        Task {
            await CommandLog.userInitiated(feature: "file-explorer") {
                let result = await state.withOperation("Creating \(name)…") {
                    (try? await explorer.makeDirectory(serial: serial, path: target))
                        ?? FeatureResult(ok: false, message: "adb not found")
                }
                state.showToast(Toast(message: result.message, ok: result.ok))
            }
            reloadToken += 1
        }
    }

    private func delete(_ targets: [FsEntry]) {
        guard let serial = state.targetSerials.first else { return }
        let paths = targets.map(path(for:))
        let label = targets.count == 1 ? targets[0].name : "\(targets.count) items"
        let explorer = state.env.engine.fileExplorer
        Task {
            await CommandLog.userInitiated(feature: "file-explorer") {
                await state.withOperation("Deleting \(label)…") {
                    for path in paths {
                        let result = (try? await explorer.delete(serial: serial, path: path))
                            ?? FeatureResult(ok: false, message: "adb not found")
                        if !result.ok {
                            state.showToast(Toast(message: result.message, ok: false))
                            return
                        }
                    }
                    state.showToast(Toast(message: "Deleted \(label)", ok: true))
                }
            }
            selection = []
            reloadToken += 1
        }
    }

    private func paste() {
        guard let clipboard, let serial = state.targetSerials.first else { return }
        let destination = currentPath
        let label = clipboard.paths.count == 1
            ? (clipboard.paths[0] as NSString).lastPathComponent
            : "\(clipboard.paths.count) items"
        self.clipboard = nil
        let explorer = state.env.engine.fileExplorer
        Task {
            await CommandLog.userInitiated(feature: "file-explorer") {
                await state.withOperation("\(clipboard.isCut ? "Moving" : "Copying") \(label)…") {
                    for source in clipboard.paths {
                        let result = clipboard.isCut
                            ? (try? await explorer.move(serial: serial, from: source, toDir: destination))
                            : (try? await explorer.copy(serial: serial, from: source, toDir: destination))
                        let outcome = result ?? FeatureResult(ok: false, message: "adb not found")
                        if !outcome.ok {
                            state.showToast(Toast(message: outcome.message, ok: false))
                            return
                        }
                    }
                    state.showToast(Toast(message: "\(clipboard.isCut ? "Moved" : "Copied") \(label)", ok: true))
                }
            }
            reloadToken += 1
        }
    }

    private func pull(_ targets: [FsEntry]) {
        guard let serial = state.targetSerials.first, !targets.isEmpty else { return }

        // One file: pick its exact destination. Several: pick a folder once.
        var destinations: [(name: String, path: String, dest: URL, bytes: Int?)] = []
        if targets.count == 1, let entry = targets.first {
            guard let dest = state.askSaveLocation(suggestedName: entry.name) else { return }
            destinations = [(entry.name, path(for: entry), dest, entry.isDir ? nil : entry.size)]
        } else {
            guard let folder = state.askSaveFolder(prompt: "Pull \(targets.count) items here") else { return }
            destinations = targets.map {
                ($0.name, path(for: $0), folder.appendingPathComponent($0.name), $0.isDir ? nil : $0.size)
            }
        }

        let explorer = state.env.engine.fileExplorer
        Task {
            await CommandLog.userInitiated(feature: "file-explorer") {
                var lastDest: URL?
                for item in destinations {
                    do {
                        lastDest = try await state.withFileProgress(
                            "Pulling \(item.name)…", destination: item.dest, expectedBytes: item.bytes
                        ) {
                            try await explorer.pull(serial: serial, path: item.path, to: item.dest)
                        }
                    } catch {
                        state.showToast(Toast(message: error.localizedDescription, ok: false))
                        return
                    }
                }
                state.showToast(Toast(
                    message: destinations.count == 1 ? "Pulled \(destinations[0].name)" : "Pulled \(destinations.count) items",
                    ok: true,
                    revealPath: lastDest?.path
                ))
            }
        }
    }
}
