import ADBKit
import SwiftUI

/// Open, stop, minimize, clear, or uninstall the selected bundle's app.
struct AppManagementView: View {
    @Environment(AppState.self) private var state
    @State private var pendingAction: AppControlService.AppAction?
    @State private var confirmingAction: AppControlService.AppAction?

    var body: some View {
        if state.selectedBundle == nil {
            ContentUnavailableView(
                "No bundle selected",
                systemImage: "shippingbox",
                description: Text("Save and select an app bundle in the bar above.")
            )
        } else if state.targetSerials.isEmpty {
            ContentUnavailableView(
                "No device connected",
                systemImage: "iphone.slash",
                description: Text("Connect a device to manage apps.")
            )
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let bundle = state.selectedBundle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bundle.nickname).font(.headline)
                    Text(bundle.packageId).font(.footnote).foregroundStyle(.textMuted)
                }
            }

            HStack(spacing: 8) {
                actionButton(.open, "Open", "play.fill", prominent: true)
                actionButton(.stop, "Force Stop", "stop.fill")
                actionButton(.minimize, "Minimize", "arrow.down.right.square")
                actionButton(.clearCache, "Clear Cache", "internaldrive")
            }

            Divider()

            Text("Destructive").font(.subheadline).foregroundStyle(.textMuted)
            HStack(spacing: 8) {
                destructiveButton(.clearData, "Clear Data")
                destructiveButton(.uninstall, "Uninstall")
            }
        }
        .centeredCard()
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(
                get: { confirmingAction != nil },
                set: { if !$0 { confirmingAction = nil } }
            )
        ) {
            Button(confirmingAction == .uninstall ? "Uninstall" : "Clear Data", role: .destructive) {
                if let action = confirmingAction {
                    run(action)
                }
                confirmingAction = nil
            }
            Button("Cancel", role: .cancel) { confirmingAction = nil }
        }
    }

    private var confirmTitle: String {
        let name = state.selectedBundle?.nickname ?? "the app"
        return confirmingAction == .uninstall
            ? "Uninstall \(name)? This removes the app from the device."
            : "Clear all data for \(name)? This signs you out and wipes local storage."
    }

    private func actionButton(
        _ action: AppControlService.AppAction, _ title: String, _ icon: String, prominent: Bool = false
    ) -> some View {
        Button {
            run(action)
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(BorderedButtonStyle())
        .tint(prominent ? .brandAccent : nil)
        .disabled(pendingAction != nil)
    }

    private func destructiveButton(_ action: AppControlService.AppAction, _ title: String) -> some View {
        Button(role: .destructive) {
            confirmingAction = action
        } label: {
            Label(title, systemImage: "trash")
                .foregroundStyle(.danger)
        }
        .disabled(pendingAction != nil)
    }

    private func run(_ action: AppControlService.AppAction) {
        guard let packageId = state.selectedBundle?.packageId else { return }
        pendingAction = action
        Task {
            await CommandLog.userInitiated(feature: "app-management") {
                for serial in state.targetSerials {
                    let result = (try? await state.env.engine.appControl.control(
                        serial: serial, packageId: packageId, action: action
                    )) ?? FeatureResult(ok: false, message: "adb not found")
                    state.showToast(Toast(message: result.message, ok: result.ok))
                }
            }
            pendingAction = nil
        }
    }
}
