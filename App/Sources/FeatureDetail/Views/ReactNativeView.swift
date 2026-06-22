import ADBKit
import SwiftUI

/// React Native hub — dev menu, JS reload, process death, dev-server host, and
/// saved deep links on one scrollable screen. The individual actions stay
/// available from search and global hotkeys; this just gathers them so the
/// sidebar isn't five rows of RN tools.
struct ReactNativeView: View {
    @Environment(AppState.self) private var state
    @AppStorage("rnDevHost") private var devHost = ""

    var body: some View {
        Form {
            Section("Quick actions") {
                HStack(spacing: 10) {
                    actionButton("reload-js", "Reload JS", "arrow.clockwise", prominent: true)
                    actionButton("open-dev-menu", "Dev Menu", "filemenu.and.selection")
                    actionButton("process-death", "Process Death", "xmark.octagon")
                }
                if state.targetSerials.isEmpty {
                    Text("Connect a device to use these.")
                        .font(.footnote)
                        .foregroundStyle(.textMuted)
                }
            }

            Section("Dev server host") {
                HStack(spacing: 8) {
                    TextField("Dev server host", text: $devHost, prompt: Text("192.168.1.10:8081"))
                        .brandField()
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    Button("Set") {
                        run("rn-dev-host", ["host": .string(devHost.trimmingCharacters(in: .whitespaces))])
                    }
                    .disabled(state.targetSerials.isEmpty || devHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            DeepLinksSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func actionButton(_ id: String, _ title: String, _ icon: String, prominent: Bool = false) -> some View {
        let content = Label(title, systemImage: icon)
        if prominent {
            Button { run(id) } label: { content }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.targetSerials.isEmpty || state.isRunningFeature)
        } else {
            Button { run(id) } label: { content }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(state.targetSerials.isEmpty || state.isRunningFeature)
        }
    }

    private func run(_ id: String, _ params: [String: FeatureValue] = [:]) {
        guard let feature = FeatureRegistry.byID[id] else { return }
        Task { await state.run(feature: feature, params: params) }
    }
}
