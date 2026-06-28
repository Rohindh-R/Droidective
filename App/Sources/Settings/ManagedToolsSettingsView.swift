import ADBKit
import AppKit
import SwiftUI

/// Lists the tools Droidective downloads from GitHub releases (jadx, apktool,
/// uber-apk-signer, and a Temurin JRE), each with its installed version and a
/// one-click download / upgrade. frida-server and frida-gadget are
/// architecture-specific and managed from the Frida screen with a device attached.
struct ManagedToolsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var versions: [ManagedTool: String] = [:]
    @State private var upgrades: [ManagedTool: String] = [:]
    @State private var busy: ManagedTool?
    @State private var checking = false
    @State private var error: String?
    @State private var download = DownloadState()
    @State private var cacheSize: Int64 = 0

    private struct Item {
        let tool: ManagedTool
        let name: String
        let purpose: String
    }

    private static let items: [Item] = [
        Item(tool: .jadx, name: "jadx", purpose: "Decompile APKs to Java"),
        Item(tool: .apktool, name: "apktool", purpose: "Disassemble & rebuild APKs"),
        Item(tool: .uberApkSigner, name: "uber-apk-signer", purpose: "Batch APK signing"),
        Item(tool: .temurinJre, name: "Temurin JRE", purpose: "Java runtime for the tools above"),
    ]

    private func arch(for tool: ManagedTool) -> String {
        tool == .temurinJre ? ManagedToolStore.macArch : ""
    }

    var body: some View {
        Form {
            Section {
                Text("Downloaded from each tool's GitHub releases and kept in Application Support. frida-server and frida-gadget are device-specific — manage them from the Frida screen.")
                    .font(.footnote).foregroundStyle(.textMuted)
            }
            Section("Tools") {
                ForEach(Self.items, id: \.tool) { row($0) }
            }
            Section {
                Button { Task { await checkForUpdates() } } label: {
                    Label(checking ? "Checking…" : "Check for updates", systemImage: "arrow.clockwise")
                }
                .disabled(checking || busy != nil)
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
            Section("Decompiled cache") {
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                HStack {
                    Button("Clear now") { clearCache() }.disabled(cacheSize == 0)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.decompiledCacheDir])
                    }
                    .disabled(cacheSize == 0)
                }
                Text("jadx/apktool output — reused while the app is open and cleared automatically when you quit. The downloaded tools above are kept.")
                    .font(.footnote).foregroundStyle(.textMuted)
            }
        }
        .formStyle(.grouped)
        .task {
            await loadVersions()
            cacheSize = await Task.detached { Self.cacheBytes() }.value
        }
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        let installed = versions[item.tool]
        LabeledContent {
            if busy == item.tool {
                if let fraction = download.fraction {
                    ProgressView(value: fraction).frame(width: 90)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if installed == nil {
                Button("Download") { Task { await install(item.tool) } }.disabled(busy != nil)
            } else if let upgrade = upgrades[item.tool] {
                Button("Update to \(upgrade)") { Task { await install(item.tool) } }.disabled(busy != nil)
            } else {
                Text("up to date").font(.caption).foregroundStyle(.textMuted)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(installed.map { "Installed \($0)" } ?? item.purpose)
                    .font(.caption).foregroundStyle(.textMuted)
            }
        }
    }

    private func loadVersions() async {
        for item in Self.items {
            versions[item.tool] = await state.env.engine.managedTools.installedVersion(item.tool)
        }
    }

    private func checkForUpdates() async {
        checking = true
        error = nil
        defer { checking = false }
        for item in Self.items where versions[item.tool] != nil {
            do {
                if let newer = try await state.env.engine.managedTools.upgradeAvailable(item.tool, arch: arch(for: item.tool)) {
                    upgrades[item.tool] = newer
                }
            } catch {
                self.error = "Couldn't check \(item.name): \(error.localizedDescription)"
            }
        }
    }

    private func install(_ tool: ManagedTool) async {
        busy = tool
        error = nil
        let progress = download
        progress.begin(tool.rawValue)
        defer { busy = nil; progress.finish() }
        do {
            let onProgress: @Sendable (Double) -> Void = { value in Task { @MainActor in progress.update(value) } }
            let path = try await state.env.engine.managedTools.install(tool, arch: arch(for: tool), onProgress: onProgress)
            versions[tool] = await state.env.engine.managedTools.installedVersion(tool)
            upgrades[tool] = nil
            if let version = versions[tool] {
                state.showToast(Toast(
                    message: "Downloaded \(tool.rawValue) \(version)", ok: true, copyText: path, revealPath: path))
            }
        } catch {
            self.error = "Couldn't download \(tool.rawValue): \(error.localizedDescription)"
        }
    }

    private func clearCache() {
        try? FileManager.default.removeItem(at: AppPaths.decompiledCacheDir)
        cacheSize = 0
    }

    /// Total bytes under the decompiled cache. Pure file I/O — call it off the
    /// main actor (a deep tree of thousands of files would block the UI).
    private nonisolated static func cacheBytes() -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: AppPaths.decompiledCacheDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
