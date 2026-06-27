import ADBKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Install an APK onto the selected device(s): drag an `.apk` onto the drop zone
/// or pick one with the file button. Reinstalls with `adb install -r` (keeps
/// data), and installs on every targeted device when run-on-all is on.
struct InstallAppView: View {
    @Environment(AppState.self) private var state
    @State private var dropTargeted = false
    @State private var installing = false
    @State private var lastResult: String?
    /// APK(s) opened from Finder (double-click / Open With), staged for an
    /// explicit Install rather than installing on arrival.
    @State private var staged: [URL] = []
    /// aapt2-parsed details per staged APK (app name, version, SDK), shown in the
    /// card. Populated asynchronously; falls back to file name + size.
    @State private var apkInfos: [URL: ApkInfo] = [:]

    private var targets: [Device] {
        state.devices.filter { state.targetSerials.contains($0.serial) }
    }

    var body: some View {
        VStack(spacing: 16) {
            if staged.isEmpty {
                dropZone
            } else {
                stagedCard
            }
            targetSummary
            if let lastResult {
                Text(lastResult)
                    .font(.callout)
                    .foregroundStyle(.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: 600, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { consumePending() }
        .onChange(of: state.pendingInstallAPKs) { _, _ in consumePending() }
        .task(id: staged) { await inspectStaged() }
    }

    /// An APK opened from Finder, staged and awaiting an explicit Install (the
    /// target is the device bar's current selection).
    private var stagedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 46))
                .foregroundStyle(.brandAccent)
            VStack(spacing: 6) {
                Text(staged.count == 1 ? "Ready to install" : "Ready to install \(staged.count) APKs")
                    .font(.title3.weight(.medium))
                ForEach(staged, id: \.self) { url in
                    apkRow(url)
                }
            }
            HStack(spacing: 10) {
                Button("Clear") { staged = [] }
                    .disabled(installing)
                Button(installing ? "Installing…" : "Install") { install(staged) }
                    .buttonStyle(.borderedProminent)
                    .disabled(installing || targets.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.horizontal, 16)
        .background(.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.brandAccent, lineWidth: 2)
        }
    }

    private func consumePending() {
        guard !state.pendingInstallAPKs.isEmpty else { return }
        staged = state.pendingInstallAPKs
        state.pendingInstallAPKs = []
    }

    /// Read each staged APK's badging so the card shows what it is. Falls back to
    /// file name + size when aapt2 (from the SDK build-tools) isn't installed.
    private func inspectStaged() async {
        var resolved: [URL: ApkInfo] = [:]
        for url in staged {
            resolved[url] = await state.env.engine.appInstall.inspect(apkPath: url.path)
        }
        guard !Task.isCancelled else { return }
        apkInfos = resolved
    }

    /// One staged APK: app name (or file name) with a package · version · SDK ·
    /// size subtitle once aapt2 has resolved it.
    @ViewBuilder private func apkRow(_ url: URL) -> some View {
        let info = apkInfos[url]
        VStack(spacing: 1) {
            Text(info?.label ?? url.lastPathComponent)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let info {
                Text(apkSubtitle(info))
                    .font(.caption)
                    .foregroundStyle(.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func apkSubtitle(_ info: ApkInfo) -> String {
        var parts: [String] = []
        if let package = info.packageName { parts.append(package) }
        if let version = info.versionName { parts.append("v\(version)") }
        if let target = info.targetSdk { parts.append("SDK \(target)") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(info.fileSizeBytes), countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: installing ? "arrow.down.circle.dotted" : "arrow.down.app")
                .font(.system(size: 46))
                .foregroundStyle(.brandAccent)
            Text(installing ? "Installing…" : "Drag an APK here")
                .font(.title3.weight(.medium))
            Button("Choose APK…") { pickAndInstall() }
                .disabled(installing)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    dropTargeted ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.borderSubtle),
                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [7])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let apk = urls.first(where: { $0.pathExtension.lowercased() == "apk" }) else { return false }
            install([apk])
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private var targetSummary: some View {
        if targets.isEmpty {
            Label("Connect a device to install onto", systemImage: "iphone.slash")
                .font(.callout)
                .foregroundStyle(.textMuted)
        } else {
            Text("Installs on \(targets.map(\.label).joined(separator: ", "))")
                .font(.callout)
                .foregroundStyle(.textMuted)
                .multilineTextAlignment(.center)
        }
    }

    private func pickAndInstall() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { install([url]) }
    }

    private func install(_ urls: [URL]) {
        let serials = targets.map(\.serial)
        guard !urls.isEmpty, !serials.isEmpty else {
            state.showToast(Toast(message: "Connect a device first", ok: false))
            return
        }
        installing = true
        Task {
            let summary = await state.installAPKs(urls, onSerials: serials)
            lastResult = summary.isEmpty ? nil : summary
            installing = false
            staged = []
        }
    }
}
