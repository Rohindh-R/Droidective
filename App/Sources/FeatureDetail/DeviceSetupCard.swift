import ADBKit
import SwiftUI

/// Friendly first-run / no-device guidance instead of a bare empty state.
struct DeviceSetupCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.gen3.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Connect an Android device")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                step(1, "On the device, open **Settings → About phone** and tap **Build number** 7 times to enable Developer options.")
                step(2, "In **Developer options**, turn on **USB debugging**.")
                step(3, "Plug in via USB and tap **Allow** on the device's debugging prompt.")
            }
            .frame(maxWidth: 440)

            HStack(spacing: 10) {
                Button {
                    state.selectedFeatureID = "wireless-adb"
                } label: {
                    Label("Connect wirelessly instead", systemImage: "wifi")
                }
                Button {
                    state.refreshDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            if state.adbMissing {
                Label("adb isn't installed yet — use the Install button in the bar above first.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .frame(width: 22, height: 22)
                .background(.tint.opacity(0.15), in: Circle())
            Text(.init(text))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
