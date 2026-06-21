import ADBKit
import SwiftUI

/// Dev-time system-restriction toggles. The install/API toggles are no-root
/// global settings; SELinux and remount appear only on a rooted device.
struct SystemRestrictionsView: View {
    @Environment(AppState.self) private var state
    @State private var current: RestrictionsState?
    @State private var hasRoot = false
    @State private var busy = false

    private var serial: String { state.targetSerials.first ?? "" }

    var body: some View {
        Group {
            if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to change restrictions.")
                )
            } else if let current {
                form(current).disabled(busy)
            } else {
                ProgressView("Reading current settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: state.targetSerials.first ?? "") { await load() }
    }

    private func form(_ state0: RestrictionsState) -> some View {
        Form {
            Section {
                SwitchRow("Verify apps installed via ADB", isOn: binding(state0.adbInstallVerification) {
                    try await engine.restrictions.setAdbInstallVerification(serial: serial, $0)
                })
                SwitchRow("Package verifier", isOn: binding(state0.packageVerifier) {
                    try await engine.restrictions.setPackageVerifier(serial: serial, $0)
                })
                SwitchRow("Enforce hidden-API restrictions", isOn: binding(state0.hiddenApiEnforced) {
                    try await engine.restrictions.setHiddenApiEnforced(serial: serial, $0)
                })
                SwitchRow("Stay awake while charging", isOn: binding(state0.stayAwake) {
                    try await engine.restrictions.setStayAwake(serial: serial, $0)
                })
            } header: {
                HStack {
                    Text("Installs & APIs")
                    Spacer()
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                }
            }
            Section("Root") {
                if hasRoot {
                    SwitchRow("SELinux enforcing", isOn: binding(state0.selinuxEnforcing ?? true) {
                        try await engine.restrictions.setSelinuxEnforcing(serial: serial, $0)
                    })
                    Button("Remount /system read-write") {
                        Task { await apply { try await engine.restrictions.remountSystemReadWrite(serial: serial) } }
                    }
                } else {
                    Text("Connect a rooted device to relax SELinux or remount the system partition.")
                        .font(.callout)
                        .foregroundStyle(.textMuted)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .centeredColumn()
    }

    private var engine: FeatureEngine { state.env.engine }

    private func binding(_ value: Bool, _ operation: @escaping (Bool) async throws -> AdbResult) -> Binding<Bool> {
        Binding(
            get: { value },
            set: { newValue in Task { await self.apply { try await operation(newValue) } } }
        )
    }

    private func apply(_ operation: @escaping () async throws -> AdbResult) async {
        busy = true
        defer { busy = false }
        await CommandLog.userInitiated(feature: "system-restrictions") {
            do {
                let result = try await operation()
                if !result.succeeded {
                    let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                    state.showToast(Toast(message: "Failed — \(detail)", ok: false))
                }
            } catch {
                state.showToast(Toast(message: error.localizedDescription, ok: false))
            }
        }
        await load()
    }

    private func load() async {
        guard !serial.isEmpty else { return }
        let result = await CommandLog.userInitiated(feature: "system-restrictions") { () -> (RestrictionsState, Bool) in
            let restrictions = await engine.restrictions.current(serial: serial)
            let rooted = await engine.root.detect(serial: serial).hasRootShell
            return (restrictions, rooted)
        }
        guard !Task.isCancelled else { return }
        current = result.0
        hasRoot = result.1
    }
}
