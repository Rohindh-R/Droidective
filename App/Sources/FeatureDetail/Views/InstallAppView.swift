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

    private var targets: [Device] {
        state.devices.filter { state.targetSerials.contains($0.serial) }
    }

    var body: some View {
        VStack(spacing: 16) {
            dropZone
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
            install(apk)
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
        if panel.runModal() == .OK, let url = panel.url { install(url) }
    }

    private func install(_ url: URL) {
        let serials = targets.map(\.serial)
        guard !serials.isEmpty else {
            state.showToast(Toast(message: "Connect a device first", ok: false))
            return
        }
        installing = true
        let name = url.lastPathComponent
        Task {
            await CommandLog.userInitiated(feature: "install-app") {
                var ok = 0
                for serial in serials {
                    let result = (try? await state.env.engine.appInstall.install(apkPath: url.path, serial: serial))
                        ?? FeatureResult(ok: false, message: "adb not found")
                    if result.ok { ok += 1 }
                    if serials.count == 1 {
                        state.showToast(Toast(message: result.message, ok: result.ok))
                    }
                }
                if serials.count > 1 {
                    state.showToast(Toast(message: "Installed \(name) on \(ok)/\(serials.count) devices", ok: ok > 0))
                }
                lastResult = ok == serials.count
                    ? "Installed \(name)"
                    : "Installed \(name) on \(ok) of \(serials.count) devices"
            }
            installing = false
        }
    }
}
