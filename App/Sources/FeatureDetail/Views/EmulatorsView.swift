import ADBKit
import SwiftUI

/// Android Studio AVDs: launch (normal / cold boot / wipe data), see which
/// are running, and stop them.
struct EmulatorsView: View {
    @Environment(AppState.self) private var state
    @State private var avds: [Avd]?
    @State private var emulatorMissing = false
    @State private var reloadToken = 0
    @State private var wipeTarget: Avd?

    var body: some View {
        Group {
            if emulatorMissing {
                ContentUnavailableView(
                    "Emulator not found",
                    systemImage: "play.display",
                    description: Text("Install the Android Emulator from Android Studio → SDK Manager → SDK Tools.")
                )
            } else if let avds {
                if avds.isEmpty {
                    ContentUnavailableView(
                        "No AVDs",
                        systemImage: "play.display",
                        description: Text("Create a virtual device in Android Studio → Device Manager, then refresh.")
                    )
                } else {
                    list(avds)
                }
            } else {
                ProgressView("Reading AVDs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Re-resolves running state as devices come and go.
        .task(id: "\(state.devices.map(\.serial).joined())|\(reloadToken)") {
            await load()
        }
    }

    private func list(_ avds: [Avd]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(avds.count) virtual devices")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    reloadToken += 1
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            .padding(8)
            Divider()

            List(avds) { avd in
                HStack {
                    Image(systemName: avd.runningSerial != nil ? "play.display" : "display")
                        .foregroundStyle(avd.runningSerial != nil ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(avd.displayName)
                        if let serial = avd.runningSerial {
                            Text("Running — \(serial)")
                                .font(.footnote)
                                .foregroundStyle(.green)
                        }
                    }
                    Spacer()

                    if let serial = avd.runningSerial {
                        Button("Stop") {
                            stop(serial: serial, name: avd.displayName)
                        }
                        .controlSize(.small)
                    } else {
                        Button("Launch") {
                            launch(avd, options: EmulatorService.LaunchOptions())
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Menu {
                            Button("Cold Boot (skip snapshot)") {
                                launch(avd, options: EmulatorService.LaunchOptions(coldBoot: true))
                            }
                            Button("Wipe Data & Launch…", role: .destructive) {
                                wipeTarget = avd
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .confirmationDialog(
            "Wipe all data on \(wipeTarget?.displayName ?? "")? Apps, accounts, and settings on the AVD are erased.",
            isPresented: Binding(get: { wipeTarget != nil }, set: { if !$0 { wipeTarget = nil } })
        ) {
            Button("Wipe & Launch", role: .destructive) {
                if let avd = wipeTarget {
                    launch(avd, options: EmulatorService.LaunchOptions(wipeData: true))
                }
                wipeTarget = nil
            }
            Button("Cancel", role: .cancel) { wipeTarget = nil }
        }
    }

    private func load() async {
        guard await state.env.engine.emulators.emulatorInstalled() else {
            emulatorMissing = true
            return
        }
        emulatorMissing = false
        let result = await CommandLog.userInitiated(feature: "emulators") {
            await state.env.engine.emulators.listAvds(devices: state.devices)
        }
        guard !Task.isCancelled else { return }
        avds = result
    }

    private func launch(_ avd: Avd, options: EmulatorService.LaunchOptions) {
        Task {
            await CommandLog.userInitiated(feature: "emulators") {
                let result = await state.env.engine.emulators.launch(avd: avd.name, options: options)
                state.showToast(Toast(message: result.message, ok: result.ok))
                // The device monitor picks the emulator up once adb sees it.
            }
        }
    }

    private func stop(serial: String, name: String) {
        Task {
            await CommandLog.userInitiated(feature: "emulators") {
                let result = (try? await state.env.engine.emulators.stop(serial: serial))
                    ?? FeatureResult(ok: false, message: "adb not found")
                state.showToast(Toast(message: result.ok ? "Stopping \(name)…" : result.message, ok: result.ok))
            }
            try? await Task.sleep(for: .seconds(2))
            state.refreshDevices()
            reloadToken += 1
        }
    }
}
