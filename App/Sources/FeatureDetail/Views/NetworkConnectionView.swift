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
                        .brandField()
                        .labelsHidden()
                        .frame(maxWidth: 140)
                    Button("Forward") {
                        run("reverse-port", ["port": .string(reversePort.trimmingCharacters(in: .whitespaces))])
                    }
                    .disabled(state.targetSerials.isEmpty || reversePort.trimmingCharacters(in: .whitespaces).isEmpty)
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
