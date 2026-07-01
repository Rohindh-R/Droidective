import ADBKit
import SwiftUI

/// Dev-time system-restriction toggles. The install/API toggles are no-root
/// global settings; SELinux and remount appear only on a rooted device.
struct SystemRestrictionsView: View {
    @Environment(AppState.self) private var state
    @State private var current: RestrictionsState?
    @State private var hasRoot = false
    @State private var refreshBusy = false

    private var serial: String { state.targetSerials.first ?? "" }

    var body: some View {
        Group {
            if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to change restrictions.")
                )
            } else if current != nil {
                form
            } else {
                ProgressView("Reading current settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: state.targetSerials.first ?? "") { await load() }
    }

    private var form: some View {
        HubColumn {
            HubSection("Installs & APIs", accessory: {
                Button {
                    Task { await refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                    .disabled(refreshBusy)
            }) {
                SwitchRow("Verify apps installed via ADB", isOn: binding(\.adbInstallVerification) {
                    try await engine.restrictions.setAdbInstallVerification(serial: serial, $0)
                })
                SwitchRow("Package verifier", isOn: binding(\.packageVerifier) {
                    try await engine.restrictions.setPackageVerifier(serial: serial, $0)
                })
                SwitchRow("Enforce hidden-API restrictions", isOn: binding(\.hiddenApiEnforced) {
                    try await engine.restrictions.setHiddenApiEnforced(serial: serial, $0)
                })
                SwitchRow("Stay awake while charging", isOn: binding(\.stayAwake) {
                    try await engine.restrictions.setStayAwake(serial: serial, $0)
                })
            }

            HubSection("Root") {
                if hasRoot {
                    SwitchRow("SELinux enforcing", isOn: selinuxBinding)
                    Button("Remount /system read-write") {
                        Task { await applyAction { try await engine.restrictions.remountSystemReadWrite(serial: serial) } }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("Connect a rooted device to relax SELinux or remount the system partition.")
                        .font(.callout)
                        .foregroundStyle(.textMuted)
                }
            }
        }
    }

    private var engine: FeatureEngine { state.env.engine }

    /// Binding that optimistically updates the one toggled field immediately so
    /// no other row re-renders. Never sets `refreshBusy`, so the rest of the
    /// form stays fully interactive during the adb round-trip.
    private func binding(
        _ path: WritableKeyPath<RestrictionsState, Bool>,
        _ operation: @escaping @Sendable (Bool) async throws -> AdbResult
    ) -> Binding<Bool> {
        Binding(
            get: { current?[keyPath: path] ?? false },
            set: { newValue in
                Task { @MainActor in
                    self.current?[keyPath: path] = newValue
                    await self.applyToggle { try await operation(newValue) }
                }
            }
        )
    }

    private var selinuxBinding: Binding<Bool> {
        Binding(
            get: { current?.selinuxEnforcing ?? true },
            set: { newValue in
                Task { @MainActor in
                    self.current?.selinuxEnforcing = newValue
                    await self.applyToggle {
                        try await engine.restrictions.setSelinuxEnforcing(serial: serial, newValue)
                    }
                }
            }
        )
    }

    /// Fire-and-forget for checkbox toggles: no busy flag → no whole-form disable flash.
    /// Reloads only on failure to resync the actual device state; on success the
    /// optimistic value is kept. This relies on every toggle's setter writing a value
    /// that round-trips back to the same boolean through `load()`'s parse — a setter
    /// the device normalizes differently would leave a stale optimistic value, so a
    /// new toggle that doesn't round-trip must reload on success here too.
    private func applyToggle(_ operation: @escaping @Sendable () async throws -> AdbResult) async {
        await CommandLog.userInitiated(feature: "system-restrictions") {
            do {
                let result = try await operation()
                if !result.succeeded {
                    let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                    state.showToast(Toast(message: "Failed — \(detail)", ok: false))
                    await load()
                }
            } catch {
                state.showToast(Toast(message: error.localizedDescription, ok: false))
                await load()
            }
        }
    }

    /// Used for explicit actions (remount) that need the busy spinner.
    private func applyAction(_ operation: @escaping @Sendable () async throws -> AdbResult) async {
        refreshBusy = true
        defer { refreshBusy = false }
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
    }

    private func refresh() async {
        refreshBusy = true
        defer { refreshBusy = false }
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
