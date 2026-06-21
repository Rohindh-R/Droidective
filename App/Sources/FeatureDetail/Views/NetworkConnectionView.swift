import ADBKit
import SwiftUI

/// Connection hub — copy the device IP, forward a port, drop a wireless
/// connection, set Private DNS, and run the wireless ADB pairing flow on one
/// scrollable screen. Copy IP also stays a one-click sidebar action; the other
/// gathered features stay searchable and hotkey-able. Wi-Fi, Network Speed, and
/// Emulators remain their own screens.
struct NetworkConnectionView: View {
    @Environment(AppState.self) private var state
    @State private var reversePort = "8081"
    @State private var disconnectTarget = ""

    var body: some View {
        Form {
            Section("Quick") {
                Button {
                    run("get-ip")
                } label: {
                    Label("Copy device IP", systemImage: "globe")
                }
                .disabled(state.targetSerials.isEmpty)
            }

            Section("Reverse port") {
                HStack(spacing: 8) {
                    TextField("Port", text: $reversePort, prompt: Text("8081"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: 140)
                    Button("Forward") {
                        run("reverse-port", ["port": .string(reversePort.trimmingCharacters(in: .whitespaces))])
                    }
                    .disabled(state.targetSerials.isEmpty || reversePort.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Disconnect wireless") {
                HStack(spacing: 8) {
                    TextField("Target", text: $disconnectTarget, prompt: Text("ip:port — blank disconnects all"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    Button("Disconnect") {
                        let target = disconnectTarget.trimmingCharacters(in: .whitespaces)
                        run("disconnect", target.isEmpty ? [:] : ["target": .string(target)])
                    }
                }
            }

            PrivateDnsSection()
            WirelessAdbSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func run(_ id: String, _ params: [String: FeatureValue] = [:]) {
        guard let feature = FeatureRegistry.byID[id] else { return }
        Task { await state.run(feature: feature, params: params) }
    }
}
