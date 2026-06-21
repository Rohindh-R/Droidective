import ADBKit
import SwiftUI

/// Persistent device context above the detail pane. A two-row grid keeps the
/// device and bundle rows' icons, pickers, and trailing actions aligned.
struct DeviceBarView: View {
    @Environment(AppState.self) private var state
    @State private var showBundleManager = false
    @State private var showInstalledApps = false

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 10) {
            Button {
                state.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.title3)
                    .frame(width: 30, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show or hide the sidebar (⌘B)")

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Image(systemName: "iphone")
                    .foregroundStyle(.textMuted)
                    .gridColumnAlignment(.center)

                deviceControl
                    .frame(width: 250, alignment: .leading)

                // Flexible middle column pushes trailing controls right.
                HStack(spacing: 8) {
                    OverridesPillView()
                    if state.adbMissing {
                        Label("adb not found", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Button(state.installingTool == .adb ? "Installing…" : "Install") {
                            state.installTool(.adb)
                        }
                        .controlSize(.mini)
                        .disabled(state.installingTool != nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Toggle("Run on all", isOn: $state.runOnAll)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(state.recordingActive)
                        .onChange(of: state.runOnAll) { state.persistSelection() }

                    Button {
                        state.refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Refresh devices")
                }
                .gridColumnAlignment(.trailing)
            }

            // The bundle row only appears when the selected feature actually
            // works with an app bundle.
            if bundleRowVisible {
                GridRow {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.textMuted)
                        .gridColumnAlignment(.center)

                    bundleControl
                        .frame(width: 250, alignment: .leading)

                    Color.clear.frame(height: 1)

                    Color.clear
                        .frame(width: 1, height: 1)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bgSurface)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .sheet(isPresented: $showBundleManager) {
            BundleManagerView()
        }
        .sheet(isPresented: $showInstalledApps) {
            InstalledAppsPickerView()
        }
    }

    @ViewBuilder
    private var deviceControl: some View {
        @Bindable var state = state
        if state.devices.isEmpty {
            Text("No device connected")
                .font(.callout)
                .foregroundStyle(.textMuted)
        } else {
            Picker("Device", selection: $state.selectedSerial) {
                ForEach(state.devices) { device in
                    Text(state.deviceTitle(device)).tag(Optional(device.serial))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .disabled(state.runOnAll || state.recordingActive)
            .help(state.recordingActive ? "Stop the recording to change the device" : "")
            .onChange(of: state.selectedSerial) { state.persistSelection() }
        }
    }

    /// True when the selected feature works with an app bundle. Custom
    /// commands (commands may require one) and logcat (its app filter is
    /// driven by saved bundles) are included.
    private var bundleRowVisible: Bool {
        guard let id = state.selectedFeatureID,
              let feature = FeatureRegistry.byID[id] else { return false }
        return feature.needsBundle
            || feature.id == "custom-commands"
            || feature.id == "logcat"
            || feature.id == "performance"
    }

    /// One menu does everything: pick (auto-selects), add from the device's
    /// installed apps, grab the on-screen app, add manually, manage.
    private var bundleControl: some View {
        Menu {
            ForEach(state.bundles) { bundle in
                Button {
                    state.selectBundle(bundle.id)
                } label: {
                    if bundle.id == state.selectedBundleId {
                        Label("\(bundle.nickname) — \(bundle.packageId)", systemImage: "checkmark")
                    } else {
                        Text("\(bundle.nickname) — \(bundle.packageId)")
                    }
                }
            }
            if !state.bundles.isEmpty {
                Divider()
            }
            Button {
                showInstalledApps = true
            } label: {
                Label("Add from installed apps", systemImage: "plus.app")
            }
            .disabled(state.targetSerials.isEmpty)
            Button {
                state.adoptForegroundApp()
            } label: {
                Label("Use app on device screen", systemImage: "scope")
            }
            .disabled(state.targetSerials.isEmpty)
            Button {
                showBundleManager = true
            } label: {
                Label("Add manually / manage…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Text(state.selectedBundle.map { "\($0.nickname) — \($0.packageId)" } ?? "Choose app bundle…")
                .lineLimit(1)
        }
        .controlSize(.small)
        .disabled(state.recordingActive)
        .help(state.recordingActive ? "Stop the recording to change the app bundle" : "")
    }

}
