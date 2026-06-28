import ADBKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Decompile a local `.apk` and browse the result: jadx for readable Java,
/// apktool for smali + decoded resources. The tools (and a Java runtime if
/// none is detected) are downloaded on demand from a point-of-use prompt.
struct DecompileBrowserView: View {
    @Environment(AppState.self) private var state
    @State private var apkURL: URL?
    @State private var mode: DecompileService.Mode = .jadx
    @State private var root: FileNode?
    @State private var selection: String?
    @State private var fileText: String?
    @State private var busy = false
    @State private var status: String?
    @State private var toolReady = false
    @State private var dropTargeted = false
    @State private var download = DownloadState()

    var body: some View {
        Group {
            if apkURL == nil {
                dropZone
            } else if !toolReady {
                // Stays up during the download too — its progress bar lives here.
                downloadGate
            } else if let root {
                browser(root)
            } else {
                progress
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(apkURL?.path ?? "")-\(mode.rawValue)") { await start() }
    }

    // MARK: - States

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "curlybraces.square")
                .font(.system(size: 46)).foregroundStyle(.brandAccent)
            Text("Drag an APK here to decompile").font(.title3.weight(.medium))
            Button("Choose APK…") { choose() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bgSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    dropTargeted ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.borderSubtle),
                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [7]))
                .padding(24)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let apk = urls.first(where: { $0.pathExtension.lowercased() == "apk" }) else { return false }
            stage(apk)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private var progress: some View {
        VStack(spacing: 12) {
            if busy {
                ProgressView()
                Text(status ?? "Decompiling…").foregroundStyle(.textMuted)
            } else {
                // Tools ready but no tree and not working = the decompile failed.
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.orange)
                Text(status ?? "Decompilation failed.")
                    .foregroundStyle(.textMuted).multilineTextAlignment(.center).frame(maxWidth: 480)
                Button("Try again") { Task { await runDecompile() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var downloadGate: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle").font(.system(size: 44)).foregroundStyle(.brandAccent)
            Text("\(mode == .jadx ? "jadx" : "apktool") isn't installed yet")
                .font(.title3.weight(.medium))
            Text("Droidective downloads it from GitHub releases (and a Java runtime if you don't have one) and keeps it up to date.")
                .font(.callout).foregroundStyle(.textMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if download.active {
                downloadProgress
            } else if let status {
                Text(status).font(.caption).foregroundStyle(.textMuted)
            }
            HStack {
                modePicker
                Button(busy ? "Setting up…" : "Download & decompile") { Task { await ensureToolsAndDecompile() } }
                    .buttonStyle(.borderedProminent).disabled(busy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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

    private func browser(_ root: FileNode) -> some View {
        VStack(spacing: 0) {
            HStack {
                modePicker
                Spacer()
                Text(apkURL?.lastPathComponent ?? "").font(.caption).foregroundStyle(.textMuted)
                Button("Decompile another…") { apkURL = nil; self.root = nil }
            }
            .padding(8)
            Divider()
            HStack(spacing: 0) {
                List(selection: $selection) {
                    OutlineGroup(root.children ?? [], children: \.children) { node in
                        Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
                            .tag(node.path)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 300)
                Divider()
                sourcePane
            }
        }
        .onChange(of: selection) { _, path in loadFile(path) }
    }

    private var sourcePane: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(fileText ?? "Select a file to view its contents.")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bgSurface)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Java (jadx)").tag(DecompileService.Mode.jadx)
            Text("Smali + resources (apktool)").tag(DecompileService.Mode.apktool)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(busy)
    }

    // MARK: - Actions

    private func stage(_ url: URL) {
        apkURL = url
        root = nil
        fileText = nil
        selection = nil
        status = nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { stage(url) }
    }

    /// Resolve the mode's tool + Java; decompile if both are present, else show
    /// the download gate.
    private func start() async {
        guard apkURL != nil else { return }
        let tool: ManagedTool = mode == .jadx ? .jadx : .apktool
        let hasTool = await state.env.engine.managedTools.resolve(tool) != nil
        let hasJava = await state.env.engine.toolchain.java() != nil
        toolReady = hasTool && hasJava
        if toolReady { await runDecompile() }
    }

    /// Download the mode's tool (and Java if missing), then decompile.
    private func ensureToolsAndDecompile() async {
        busy = true
        defer { busy = false }
        do {
            if await state.env.engine.toolchain.java() == nil {
                try await installTool(.temurinJre, arch: ManagedToolStore.macArch, label: "Java runtime")
            }
            let tool: ManagedTool = mode == .jadx ? .jadx : .apktool
            if await state.env.engine.managedTools.resolve(tool) == nil {
                try await installTool(tool, arch: "", label: tool.rawValue)
            }
            toolReady = true
            await runDecompile()
        } catch {
            status = "Setup failed: \(error.localizedDescription)"
        }
        download.finish()
    }

    /// Download a managed tool with progress, then post a notification with the
    /// installed version and where it was saved.
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

    private func runDecompile() async {
        guard let apkURL else { return }
        busy = true
        status = "Decompiling with \(mode == .jadx ? "jadx" : "apktool")…"
        defer { busy = false }
        do {
            let dir = try await state.env.engine.decompile.decompile(
                apkPath: apkURL.path, mode: mode, into: Self.outputRoot())
            guard !Task.isCancelled else { return }
            root = DecompileService.tree(at: dir)
            status = nil
        } catch {
            status = error.localizedDescription
            root = nil
        }
    }

    private func loadFile(_ path: String?) {
        guard let path else { fileText = nil; return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            fileText = nil
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            fileText = "Couldn't read this file."
            return
        }
        if data.count > 1_000_000 {
            fileText = "File too large to preview (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))."
        } else if let text = String(data: data, encoding: .utf8) {
            fileText = text
        } else {
            fileText = "Binary file — \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))."
        }
    }

    private static func outputRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Droidective/decompiled", isDirectory: true)
    }
}
