import ADBKit
import SwiftUI

/// React Native hub — dev menu, JS reload, process death, Metro forwarding,
/// dev-server host, saved deep links, and quick links to the logs/perf tools RN
/// work leans on. The individual actions stay available from search and global
/// hotkeys; this just gathers them so the sidebar isn't a wall of RN tools.
struct ReactNativeView: View {
    @Environment(AppState.self) private var state
    @AppStorage("rnDevHost") private var devHost = ""

    private let actionColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        HubColumn {
            HubSection("Quick actions", subtitle: "Drive the in-app dev menu and Metro over adb.") {
                LazyVGrid(columns: actionColumns, spacing: 10) {
                    actionButton("reload-js", "Reload JS", "arrow.clockwise", prominent: true)
                    actionButton("open-dev-menu", "Dev Menu", "filemenu.and.selection")
                    actionButton("process-death", "Process Death", "xmark.octagon")
                    metroButton
                }
                if state.targetSerials.isEmpty {
                    Text("Connect a device to use these.")
                        .font(.footnote)
                        .foregroundStyle(.textMuted)
                }
            }

            HubSection("Dev server host", subtitle: "Point the app at your Metro bundler and reverse-tunnel its port.") {
                HStack(spacing: 10) {
                    TextField("", text: $devHost, prompt: Text("192.168.1.10:8081"))
                        .brandField()
                        .labelsHidden()
                    Button("Set") {
                        run("rn-dev-host", ["host": .string(devHost.trimmingCharacters(in: .whitespaces))])
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.targetSerials.isEmpty || devHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            DeepLinksSection()

            HubSection("Related tools") {
                VStack(spacing: 0) {
                    relatedRow("logcat", "Logcat", "Live JS & native logs", "scroll")
                    Divider()
                    relatedRow("crash-catcher", "Crash Catcher", "Catches ReactNativeJS crashes", "exclamationmark.triangle")
                    Divider()
                    relatedRow("performance", "Performance Monitor", "Live CPU, RAM & FPS", "chart.line.uptrend.xyaxis")
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ id: String, _ title: String, _ icon: String, prominent: Bool = false) -> some View {
        let label = Label(title, systemImage: icon).frame(maxWidth: .infinity)
        if prominent {
            Button { run(id) } label: { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.targetSerials.isEmpty || state.isRunningFeature)
        } else {
            Button { run(id) } label: { label }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(state.targetSerials.isEmpty || state.isRunningFeature)
        }
    }

    /// Reverse-tunnel Metro's 8081 so a USB device reaches the local bundler —
    /// the one adb step every RN-on-device session needs (reuses Reverse Port).
    private var metroButton: some View {
        Button { run("reverse-port", ["port": .string("8081")]) } label: {
            Label("Forward Metro", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(state.targetSerials.isEmpty || state.isRunningFeature)
        .help("adb reverse tcp:8081 — reach your local Metro bundler from a USB device")
    }

    private func relatedRow(_ id: String, _ title: String, _ detail: String, _ icon: String) -> some View {
        Button {
            if let feature = FeatureRegistry.byID[id] { state.openFeature(feature) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(.textMuted).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.textMain)
                    Text(detail).font(.footnote).foregroundStyle(.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.textMuted)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private func run(_ id: String, _ params: [String: FeatureValue] = [:]) {
        guard let feature = FeatureRegistry.byID[id] else { return }
        Task { await state.run(feature: feature, params: params) }
    }
}
