import ADBKit
import SwiftUI

/// Grant/revoke runtime permissions for the selected bundle.
struct PermissionsView: View {
    @Environment(AppState.self) private var state
    @State private var permissions: [PermissionEntry]?
    @State private var mutating: String?

    var body: some View {
        Group {
            if state.selectedBundle == nil {
                ContentUnavailableView(
                    "No bundle selected", systemImage: "checkmark.shield",
                    description: Text("Select a bundle to inspect its permissions.")
                )
            } else if state.targetSerials.isEmpty {
                ContentUnavailableView(
                    "No device connected", systemImage: "iphone.slash",
                    description: Text("Connect a device to inspect permissions.")
                )
            } else if let permissions {
                if permissions.isEmpty {
                    ContentUnavailableView(
                        "No runtime permissions", systemImage: "checkmark.shield",
                        description: Text("This app declares no runtime permissions, or it isn't installed.")
                    )
                } else {
                    list(permissions)
                }
            } else {
                ProgressView("Reading permissions…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Keyed on the READY serial so the view loads once a plugged-in
        // device finishes authorizing (same serial, new readiness).
        .task(id: "\(state.selectedBundleId ?? "")|\(state.targetSerials.first ?? "")") {
            await load()
        }
    }

    private func list(_ entries: [PermissionEntry]) -> some View {
        List(entries) { entry in
            let isMutating = mutating == entry.name
            Toggle(isOn: Binding(
                get: { entry.granted },
                set: { setPermission(entry, granted: $0) }
            )) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.shortName)
                        Text(entry.name)
                            .font(.footnote)
                            .foregroundStyle(.textMuted)
                    }
                    if isMutating {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(mutating != nil)
            // While one permission is changing, dim the others so it's clear
            // the list is briefly locked.
            .opacity(mutating != nil && !isMutating ? 0.5 : 1)
        }
    }

    private func load() async {
        permissions = nil
        guard let serial = state.targetSerials.first,
              let packageId = state.selectedBundle?.packageId else { return }
        let result = await CommandLog.userInitiated(feature: "permissions") {
            (try? await state.env.engine.inspection.listPermissions(serial: serial, packageId: packageId)) ?? []
        }
        guard !Task.isCancelled else { return }
        permissions = result
    }

    private func setPermission(_ entry: PermissionEntry, granted: Bool) {
        guard let serial = state.targetSerials.first,
              let packageId = state.selectedBundle?.packageId else { return }
        mutating = entry.name
        Task {
            await CommandLog.userInitiated(feature: "permissions") {
                let result = (try? await state.env.engine.inspection.setPermission(
                    serial: serial, packageId: packageId, permission: entry.name, grant: granted
                )) ?? FeatureResult(ok: false, message: "adb not found")
                state.showToast(Toast(message: result.message, ok: result.ok))
            }
            await load()
            mutating = nil
        }
    }
}
