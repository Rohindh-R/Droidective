import ADBKit
import SwiftUI

/// Persistent device context above the detail pane. A two-row grid keeps the
/// device and bundle rows' icons, controls, and trailing actions aligned. The
/// device and app are shown as prominent pills (status dot + bold name) so the
/// active target is unmistakable.
struct DeviceBarView: View {
    @Environment(AppState.self) private var state
    @State private var showBundleManager = false
    @State private var showInstalledApps = false
    @State private var refreshSpin = 0.0

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
                    .foregroundStyle(deviceStatusColor)
                    .gridColumnAlignment(.center)
                    .help(deviceStatusHelp)

                HStack(spacing: 8) {
                    deviceControl
                    if let device = selectedDevice, device.isWireless {
                        disconnectControl(device)
                    }
                }

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

                HStack(spacing: 10) {
                    if state.readyDeviceCount > 1 {
                        Toggle(isOn: $state.runOnAll) {
                            Label("Run on all", systemImage: "square.stack.3d.up.fill")
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(state.recordingActive)
                        .onChange(of: state.runOnAll) { state.persistSelection() }
                        .help("Run actions on every connected device")
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.6)) { refreshSpin += 360 }
                        state.refreshDevices()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(.degrees(refreshSpin))
                    }
                    .controlSize(.small)
                    .help("Refresh devices")

                    NotificationBell()
                }
                .gridColumnAlignment(.trailing)
            }

            // The bundle row only appears when the selected feature actually
            // works with an app bundle.
            if bundleRowVisible {
                GridRow {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(bundleIconColor)
                        .gridColumnAlignment(.center)

                    bundleControl

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

    private var selectedDevice: Device? {
        state.devices.first { $0.serial == state.selectedSerial }
    }

    // MARK: - Device pill

    @ViewBuilder
    private var deviceControl: some View {
        @Bindable var state = state
        Menu {
            if state.devices.isEmpty {
                Text("No devices connected")
            }
            ForEach(state.devices) { device in
                Button {
                    state.requestDevice(device.serial)
                } label: {
                    if device.serial == state.selectedSerial {
                        Label(state.deviceTitle(device), systemImage: "checkmark")
                    } else {
                        Text(state.deviceTitle(device))
                    }
                }
            }
            let launchable = state.availableAvds.filter { $0.runningSerial == nil }
            if !launchable.isEmpty {
                Section("Start an emulator") {
                    ForEach(launchable) { avd in
                        Button {
                            state.launchEmulator(avd)
                        } label: {
                            Label(avd.displayName, systemImage: "play.circle")
                        }
                    }
                }
            }
            Divider()
            Button {
                state.requestFeature("emulators")
            } label: {
                Label("Manage emulators…", systemImage: "square.stack.3d.up")
            }
            Button {
                state.refreshDevices()
            } label: {
                Label("Refresh devices", systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            devicePill
        }
        .fixedSize()
        .controlSize(.large)
        .disabled(state.runOnAll || state.recordingActive)
        .help(state.recordingActive ? "Stop the recording to change the device" : "Switch the active device")
        .task(id: state.devices.map(\.serial).joined()) { await state.refreshAvds() }
    }

    /// macOS popup buttons flatten their label to one tint, so the status
    /// color lives on the leading icon (outside the menu) instead of a dot.
    private var devicePill: some View {
        Text(selectedDevice.map(state.deviceTitle) ?? "No device connected")
            .fontWeight(.semibold)
            .lineLimit(1)
    }

    private var deviceStatusColor: Color {
        guard let device = selectedDevice else { return Color("TextMuted") }
        if device.isReady { return .green }
        if device.state == "unauthorized" { return .orange }
        return .red
    }

    private var bundleIconColor: Color {
        state.selectedBundle == nil ? Color("TextMuted") : Color("BrandAccent")
    }

    private var deviceStatusHelp: String {
        guard let device = selectedDevice else { return "No device connected" }
        if device.isReady { return "\(device.label) — connected" }
        if device.state == "unauthorized" { return "\(device.label) — accept the prompt on the device" }
        return "\(device.label) — \(device.state)"
    }

    // MARK: - Disconnect

    private func disconnectControl(_ device: Device) -> some View {
        Menu {
            Button("Disconnect \(device.label)") {
                state.disconnectWireless(target: device.serial)
            }
            if state.readyWirelessDevices.count > 1 {
                Button("Disconnect all wireless") {
                    state.disconnectWireless(target: nil)
                }
            }
        } label: {
            Image(systemName: "wifi.slash")
        } primaryAction: {
            state.disconnectWireless(target: device.serial)
        }
        .fixedSize()
        .controlSize(.large)
        .tint(.red)
        .help("Disconnect \(device.label)")
        .disabled(state.recordingActive)
    }

    /// True when the selected feature works with an app bundle. Custom
    /// commands (commands may require one) and logcat (its app filter is
    /// driven by saved bundles) are included.
    private var bundleRowVisible: Bool {
        guard let id = state.activeTabID,
              let feature = FeatureRegistry.byID[id] else { return false }
        return feature.needsBundle
            || feature.id == "custom-commands"
            || feature.id == "logcat"
            || feature.id == "performance"
    }

    // MARK: - Bundle pill

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
            bundlePill
        }
        .fixedSize()
        .controlSize(.large)
        .disabled(state.recordingActive)
        .help(state.recordingActive ? "Stop the recording to change the app bundle" : "Choose the target app")
    }

    private var bundlePill: some View {
        HStack(spacing: 7) {
            if let bundle = state.selectedBundle {
                Text(bundle.nickname)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(bundle.packageId)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Choose app bundle…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
