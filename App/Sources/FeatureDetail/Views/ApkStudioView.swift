import ADBKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ApkStudioTab: String, CaseIterable, Identifiable {
    case inspect = "Inspect"
    case decompile = "Decompile"
    case recompile = "Recompile"
    case sign = "Sign"
    var id: String { rawValue }
}

/// APK Studio's loaded-APK session, owned by `AppState`. In-memory, so reopening
/// the studio resumes the same APK and tab within a run, and it's gone when the
/// app quits (along with the decompiled cache).
@MainActor @Observable final class ApkStudioSession {
    var apk: URL?
    /// A rebuilt APK from the Recompile tab — what the Sign tab signs instead of
    /// the originally loaded APK.
    var signInput: URL?
    var tab: ApkStudioTab = .inspect
}

/// One workspace over a single loaded APK: inspect it, decompile it (jadx or
/// apktool), recompile an edited apktool tree, and sign the result. The three
/// standalone APK tools (APK Inspector, Decompile, Sign) are folded in here via
/// `FeatureRegistry.absorbedByHub`, so they don't also appear as sidebar rows;
/// this view embeds them, sharing the loaded APK, and adds the Recompile step.
struct ApkStudioView: View {
    @Environment(AppState.self) private var state
    @State private var dropTargeted = false

    private var session: ApkStudioSession { state.apkStudio }

    var body: some View {
        Group {
            if let apk = session.apk { workspace(apk) } else { picker }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Workspace

    private func workspace(_ apk: URL) -> some View {
        VStack(spacing: 0) {
            header(apk)
            Divider()
            content(apk)
        }
        .background(.bgRoot)
    }

    private func header(_ apk: URL) -> some View {
        @Bindable var session = session
        return HStack(spacing: 12) {
            Picker("", selection: $session.tab) {
                ForEach(ApkStudioTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Text(apk.lastPathComponent).font(.caption).foregroundStyle(.textMuted).lineLimit(1)
            Button("Open another APK") { open(nil) }
        }
        .padding(8)
        .background(.bgSurface)
    }

    @ViewBuilder private func content(_ apk: URL) -> some View {
        switch session.tab {
        case .inspect:
            ApkInspectorView(apkURL: apk).id(apk)
        case .decompile:
            DecompileBrowserView(apkURL: apk).id(apk)
        case .recompile:
            RecompileTab(apkURL: apk) { rebuilt in
                session.signInput = rebuilt
                session.tab = .sign
            }
        case .sign:
            ApkSignView(input: session.signInput ?? apk).id(session.signInput ?? apk)
        }
    }

    // MARK: - Picker (no APK loaded yet)

    private var picker: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver").font(.system(size: 46)).foregroundStyle(.brandAccent)
            Text("Drop an APK to inspect, decompile, recompile, and sign").font(.title3.weight(.medium))
            Text("Load it once, then switch tabs — everything in one place.")
                .font(.callout).foregroundStyle(.textMuted)
            Button("Choose APK…") { choose() }
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
            open(apk)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: - Actions

    private func open(_ url: URL?) {
        session.apk = url
        session.signInput = nil
        session.tab = .inspect
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}

/// Rebuild an edited apktool tree back into an APK, then hand it to the Sign tab.
/// Decoding (`apktool d`) and rebuilding (`apktool b`) run through the shared
/// `DecompileService`; the decoded sources are revealed in Finder for editing.
/// The rebuilt APK is written to ~/Downloads/Droidective (a durable, visible
/// location), not the throwaway decompiled cache.
private struct RecompileTab: View {
    @Environment(AppState.self) private var state
    let apkURL: URL
    let onRebuilt: (URL) -> Void

    @State private var sourceDir: URL?
    @State private var busy = false
    @State private var status: String?
    @State private var failed = false
    @State private var rebuiltURL: URL?

    var body: some View {
        Form {
            Section("1 · Decode resources") {
                Text("Disassemble the APK to smali + decoded resources with apktool, so you can edit it.")
                    .font(.callout).foregroundStyle(.textMuted)
                if let sourceDir {
                    LabeledContent("Sources", value: sourceDir.lastPathComponent)
                    Button("Reveal sources in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([sourceDir])
                    }
                } else {
                    Button(busy ? "Decoding…" : "Decode with apktool") { Task { await decode() } }
                        .disabled(busy)
                }
            }
            Section("2 · Edit the files") {
                Text("Open the revealed folder in your editor, change resources / smali / the manifest, then come back.")
                    .font(.callout).foregroundStyle(.textMuted)
            }
            Section("3 · Rebuild") {
                Button(busy ? "Rebuilding…" : "Rebuild APK") { Task { await rebuild() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || sourceDir == nil)
                if let status {
                    resultRow(status)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func resultRow(_ status: String) -> some View {
        if failed {
            Label(status, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        } else if let rebuiltURL {
            VStack(alignment: .leading, spacing: 6) {
                Label(status, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                HStack {
                    Button("Sign the rebuilt APK") { onRebuilt(rebuiltURL) }
                        .buttonStyle(.borderedProminent)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([rebuiltURL])
                    }
                }
            }
        }
    }

    private func decode() async {
        busy = true
        status = nil
        failed = false
        defer { busy = false }
        do {
            sourceDir = try await state.env.engine.decompile.decompile(
                apkPath: apkURL.path, mode: .apktool, into: AppPaths.decompiledCacheDir)
        } catch {
            status = error.localizedDescription
            failed = true
        }
    }

    private func rebuild() async {
        guard let sourceDir else { return }
        busy = true
        status = nil
        failed = false
        rebuiltURL = nil
        defer { busy = false }
        let name = apkURL.deletingPathExtension().lastPathComponent
        do {
            let output = try ScreenCaptureService.ensureCaptureDir()
                .appendingPathComponent("\(name)-rebuilt.apk").path
            try await state.env.engine.decompile.rebuild(sourceDir: sourceDir.path, to: output)
            rebuiltURL = URL(fileURLWithPath: output)
            status = "Rebuilt to Downloads/Droidective — sign it before installing."
        } catch {
            status = error.localizedDescription
            failed = true
        }
    }
}
