import ADBKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Decompile a local APK and browse it: set up the decompiler (download jadx /
/// apktool + a Java runtime if needed), pick an APK, then explore a file tree
/// with file-name filtering and global code search, viewing each file in the
/// CodeMirror editor (syntax highlighting, line numbers, ⌘F find).
struct DecompileBrowserView: View {
    @Environment(AppState.self) private var state

    @State private var mode: DecompileService.Mode = .jadx
    @State private var toolReady = false
    @State private var checkingTool = true
    @State private var download = DownloadState()

    @State private var apkURL: URL?
    @State private var busy = false
    @State private var status: String?
    @State private var dropTargeted = false

    @State private var root: FileNode?
    @State private var selection: String?
    @State private var fileText: String?
    @State private var fileLanguage = ""
    @State private var targetLine = 0
    @State private var findToken = 0

    @State private var filter = ""
    @State private var searchScope: SearchScope = .name
    @State private var searchHits: [DecompileService.SearchHit] = []
    @State private var searching = false
    private let embedded: Bool

    /// A non-nil `apkURL` embeds the browser in APK Studio: it decompiles that
    /// APK directly (skipping the picker) and drops its "decompile another"
    /// button — the workspace owns APK selection.
    init(apkURL: URL? = nil) {
        _apkURL = State(initialValue: apkURL)
        embedded = apkURL != nil
    }

    private enum SearchScope: String, CaseIterable { case name = "File name", contents = "Code" }

    private var toolName: String { mode == .jadx ? "jadx" : "apktool" }

    var body: some View {
        Group {
            if checkingTool {
                centered { ProgressView() }
            } else if !toolReady {
                setupGate
            } else if apkURL == nil {
                apkPicker
            } else if let root {
                browser(root)
            } else {
                decompileStatus
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: prepKey) { await prepare() }
        .onChange(of: mode) { _, _ in root = nil; selection = nil; fileText = nil }
    }

    /// Re-key the prepare task on both the APK and the decompiler, so switching
    /// jadx ⇆ apktool (or loading a new APK) re-checks tools and decompiles.
    private var prepKey: String { "\(apkURL?.path ?? "")|\(mode.rawValue)" }

    // MARK: - Setup gate (shown first)

    private var setupGate: some View {
        VStack(spacing: 16) {
            Image(systemName: "curlybraces.square").font(.system(size: 46)).foregroundStyle(.brandAccent)
            Text("Set up the decompiler").font(.title2.weight(.semibold))
            modePicker
            VStack(alignment: .leading, spacing: 8) {
                setupRow(toolName, detail: "Decompiler — downloaded from GitHub releases, kept up to date.")
                setupRow("Java runtime", detail: "Used to run \(toolName). A detected JDK is reused; otherwise Temurin is fetched.")
            }
            .frame(maxWidth: 460)
            if download.active {
                downloadProgress
            } else if let status {
                Text(status).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            Button(download.active ? "Downloading…" : "Download \(toolName) & continue") {
                Task { await setUpTools() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(download.active)
            Text("Manage versions anytime in Settings ▸ Tools.").font(.caption).foregroundStyle(.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func setupRow(_ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.brandAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.textMuted)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.bgSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var downloadProgress: some View {
        Group {
            if let fraction = download.fraction {
                ProgressView(value: fraction) { Text(download.label ?? "Downloading…") }
            } else {
                ProgressView { Text(download.label ?? "Downloading…") }
            }
        }
        .frame(maxWidth: 360)
    }

    // MARK: - APK picker

    private var apkPicker: some View {
        VStack(spacing: 14) {
            modePicker
            Spacer()
            Image(systemName: "doc.badge.arrow.up").font(.system(size: 46)).foregroundStyle(.brandAccent)
            Text("Drag an APK here to decompile with \(toolName)").font(.title3.weight(.medium))
            Button("Choose APK…") { choose() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(.bgSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    dropTargeted ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.borderSubtle),
                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [7]))
                .padding(20)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let apk = urls.first(where: { $0.pathExtension.lowercased() == "apk" }) else { return false }
            apkURL = apk
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var modePicker: some View {
        Picker("Decompiler", selection: $mode) {
            Text("Java (jadx)").tag(DecompileService.Mode.jadx)
            Text("Smali + resources (apktool)").tag(DecompileService.Mode.apktool)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(download.active || busy)
    }

    // MARK: - Decompiling / failure

    @ViewBuilder private var decompileStatus: some View {
        centered {
            if busy {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(status ?? "Decompiling with \(toolName)…").foregroundStyle(.textMuted)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.orange)
                    Text(status ?? "Decompilation failed.")
                        .foregroundStyle(.textMuted).multilineTextAlignment(.center).frame(maxWidth: 480)
                    HStack {
                        Button("Try again") { Task { await runDecompile() } }
                        Button("Choose another APK") { apkURL = nil }
                    }
                }
            }
        }
    }

    // MARK: - Browser

    private func browser(_ root: FileNode) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                modePicker.controlSize(.small)
                Text(apkURL?.lastPathComponent ?? "").font(.caption).foregroundStyle(.textMuted).lineLimit(1)
                Spacer()
                Button { findToken += 1 } label: { Label("Find", systemImage: "magnifyingglass") }
                    .help("Find in file (⌘F)")
                Menu {
                    Button("Open APK in jadx-GUI") { Task { await openInJadxGui() } }
                    Button("Reveal decompiled files in Finder") { revealOutput() }
                } label: {
                    Label("Open externally", systemImage: "arrow.up.forward.app")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open the APK in the full jadx GUI, or reveal the files to edit them in another tool")
                if !embedded {
                    Button("Decompile another") { apkURL = nil; self.root = nil; selection = nil }
                }
            }
            .padding(8)
            Divider()
            HStack(spacing: 0) {
                sidebar(root).frame(width: 320)
                Divider()
                editorPane
            }
        }
        .background(.bgRoot)
        .onChange(of: selection) { _, path in loadInEditor(path, line: 0) }
    }

    private func sidebar(_ root: FileNode) -> some View {
        VStack(spacing: 6) {
            Picker("", selection: $searchScope) {
                ForEach(SearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField(searchScope == .name ? "Filter files…" : "Search code…", text: $filter)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if searchScope == .contents { Task { await runSearch(in: root) } } }
                .onChange(of: searchScope) { _, _ in searchHits = [] }
            Divider()
            if searchScope == .contents {
                searchResults
            } else {
                fileTree(root)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bgSurface)
    }

    @ViewBuilder private func fileTree(_ root: FileNode) -> some View {
        if let filtered = filteredNode(root, filter), let children = filtered.children {
            List(selection: $selection) {
                OutlineGroup(children, children: \.children) { node in
                    Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text").tag(node.path)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } else {
            centered { Text("No matching files").font(.callout).foregroundStyle(.textMuted) }
        }
    }

    @ViewBuilder private var searchResults: some View {
        if searching {
            centered { ProgressView() }
        } else if searchHits.isEmpty {
            centered {
                Text(filter.isEmpty ? "Type and press return to search the code" : "No matches")
                    .font(.callout).foregroundStyle(.textMuted).multilineTextAlignment(.center)
            }
        } else {
            List(searchHits) { hit in
                Button { loadInEditor(hit.path, line: hit.line) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\((hit.path as NSString).lastPathComponent):\(hit.line)").font(.caption.weight(.medium))
                        Text(hit.text).font(.caption.monospaced()).foregroundStyle(.textMuted).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var editorPane: some View {
        if let fileText {
            CodeEditorView(content: fileText, language: fileLanguage, line: targetLine, findToken: findToken)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Self.editorBackground)
        } else {
            centered { Text("Select a file to view its source.").foregroundStyle(.textMuted) }
        }
    }

    /// Matches the editor's `#282c34` (one-dark) so no window vibrancy shows
    /// through behind the web view.
    private static let editorBackground = Color(red: 0.157, green: 0.173, blue: 0.204)

    // MARK: - Actions

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { apkURL = panel.url }
    }

    private func checkTool() async {
        checkingTool = true
        let tool: ManagedTool = mode == .jadx ? .jadx : .apktool
        let hasTool = await state.env.engine.managedTools.resolve(tool) != nil
        let hasJava = await state.env.engine.toolchain.java() != nil
        toolReady = hasTool && hasJava
        checkingTool = false
    }

    private func setUpTools() async {
        do {
            if await state.env.engine.toolchain.java() == nil {
                try await installTool(.temurinJre, arch: ManagedToolStore.macArch, label: "Java runtime")
            }
            let tool: ManagedTool = mode == .jadx ? .jadx : .apktool
            if await state.env.engine.managedTools.resolve(tool) == nil {
                try await installTool(tool, arch: "", label: tool.rawValue)
            }
            status = nil
            toolReady = true
            if apkURL != nil { await runDecompile() }
        } catch {
            status = "Setup failed: \(error.localizedDescription)"
        }
        download.finish()
    }

    private func installTool(_ tool: ManagedTool, arch: String, label: String) async throws {
        let progress = download
        progress.begin("Downloading \(label)…")
        let onProgress: @Sendable (Double) -> Void = { value in Task { @MainActor in progress.update(value) } }
        let path = try await state.env.engine.managedTools.install(tool, arch: arch, onProgress: onProgress)
        let version = await state.env.engine.managedTools.installedVersion(tool) ?? ""
        state.showToast(Toast(
            message: "Downloaded \(label) \(version)".trimmingCharacters(in: .whitespaces),
            ok: true, copyText: path, revealPath: path))
    }

    private func prepare() async {
        await checkTool()
        guard toolReady, apkURL != nil else { return }
        await runDecompile()
    }

    private func runDecompile() async {
        guard let apkURL else { return }
        busy = true
        status = "Decompiling with \(toolName)…"
        defer { busy = false }
        do {
            let dir = try await state.env.engine.decompile.decompile(
                apkPath: apkURL.path, mode: mode, into: AppPaths.decompiledCacheDir)
            guard !Task.isCancelled else { return }
            root = DecompileService.tree(at: dir)
            status = nil
        } catch {
            status = error.localizedDescription
            root = nil
        }
    }

    /// Hand off to the full jadx GUI for advanced exploration (the in-app viewer
    /// stays a basic reader). Surfaces the launcher's result as a toast.
    private func openInJadxGui() async {
        guard let apkURL else { return }
        let result = await state.env.engine.decompile.launchJadxGui(apkPath: apkURL.path)
        state.showToast(Toast(message: result.message, ok: result.ok))
    }

    /// Reveal the decompiled output so it can be opened in any external editor.
    private func revealOutput() {
        guard let root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root.path)])
    }

    private func runSearch(in root: FileNode) async {
        let query = filter
        guard !query.isEmpty else { searchHits = []; return }
        searching = true
        let dir = URL(fileURLWithPath: root.path)
        let hits = await Task.detached { DecompileService.search(in: dir, query: query) }.value
        guard !Task.isCancelled else { return }
        searchHits = hits
        searching = false
    }

    /// Open a file in the editor, optionally jumping to (and highlighting) a line.
    private func loadInEditor(_ path: String?, line: Int) {
        targetLine = line
        loadFile(path)
    }

    private func loadFile(_ path: String?) {
        guard let path else { fileText = nil; return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            fileText = nil
            return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        fileLanguage = ext == "java" ? "java" : (ext == "xml" ? "xml" : "")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            fileText = "Couldn't read this file."
            return
        }
        if data.count > 2_000_000 {
            fileText = "File too large to preview (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))."
        } else {
            fileText = String(data: data, encoding: .utf8)
                ?? "Binary file — \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))."
        }
    }

    private func filteredNode(_ node: FileNode, _ query: String) -> FileNode? {
        guard !query.isEmpty else { return node }
        guard let children = node.children else {
            return node.name.localizedCaseInsensitiveContains(query) ? node : nil
        }
        let kept = children.compactMap { filteredNode($0, query) }
        return kept.isEmpty ? nil : FileNode(name: node.name, path: node.path, children: kept)
    }

}
