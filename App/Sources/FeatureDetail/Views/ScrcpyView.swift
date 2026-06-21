import ADBKit
import SwiftUI

/// Mirror Screen: common scrcpy options (persisted) + a Launch button.
struct ScrcpyView: View {
    @Environment(AppState.self) private var state

    @AppStorage("scrcpyMaxSize") private var maxSize = 0
    @AppStorage("scrcpyBitRate") private var bitRateMbps = 0
    @AppStorage("scrcpyMaxFps") private var maxFps = 0
    @AppStorage("scrcpyStayAwake") private var stayAwake = false
    @AppStorage("scrcpyTurnScreenOff") private var turnScreenOff = false
    @AppStorage("scrcpyViewOnly") private var viewOnly = false
    @AppStorage("scrcpyAlwaysOnTop") private var alwaysOnTop = false
    @AppStorage("scrcpyFullscreen") private var fullscreen = false
    @AppStorage("scrcpyRecord") private var recordToFile = false

    private var options: ScrcpyOptions {
        ScrcpyOptions(
            maxSize: maxSize, bitRateMbps: bitRateMbps, maxFps: maxFps,
            stayAwake: stayAwake, turnScreenOff: turnScreenOff, viewOnly: viewOnly,
            alwaysOnTop: alwaysOnTop, fullscreen: fullscreen
        )
    }

    var body: some View {
        Form {
            Section("Quality") {
                Picker("Max size", selection: $maxSize) {
                    Text("Unlimited").tag(0)
                    Text("1920 px").tag(1920)
                    Text("1280 px").tag(1280)
                    Text("1024 px").tag(1024)
                    Text("800 px").tag(800)
                }
                Picker("Bit rate", selection: $bitRateMbps) {
                    Text("Default").tag(0)
                    Text("2 Mbps").tag(2)
                    Text("4 Mbps").tag(4)
                    Text("8 Mbps").tag(8)
                    Text("16 Mbps").tag(16)
                }
                Picker("Max FPS", selection: $maxFps) {
                    Text("Unlimited").tag(0)
                    Text("30").tag(30)
                    Text("60").tag(60)
                    Text("120").tag(120)
                }
            }

            Section("Window") {
                SwitchRow("Fullscreen", isOn: $fullscreen)
                SwitchRow("Always on top", isOn: $alwaysOnTop)
                SwitchRow("View only (no control)", isOn: $viewOnly)
            }

            Section("Device") {
                SwitchRow("Keep device awake", isOn: $stayAwake)
                SwitchRow("Turn device screen off", isOn: $turnScreenOff)
                SwitchRow("Record session to a file", isOn: $recordToFile)
            }

            Section {
                Button {
                    state.launchMirror(options: options, recordToFile: recordToFile)
                } label: {
                    Label("Launch Mirror", systemImage: "play.display")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.targetSerials.isEmpty)
                if state.targetSerials.isEmpty {
                    Text("Connect a device to mirror.")
                        .font(.footnote)
                        .foregroundStyle(.textMuted)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .centeredColumn()
    }
}
