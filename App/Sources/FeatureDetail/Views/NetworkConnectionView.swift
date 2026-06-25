import ADBKit
import SwiftUI

/// Connection hub — copy the device IP, forward a port, set Private DNS, and run
/// the wireless ADB pairing flow on one scrollable screen. Copy IP also stays a
/// one-click sidebar action; the other gathered features stay searchable and
/// hotkey-able. Wi-Fi, Network Speed, and Emulators remain their own screens.
struct NetworkConnectionView: View {
    @Environment(AppState.self) private var state
    @State private var reversePort = "8081"

    var body: some View {
        HubColumn {
            HubSection("Device IP") {
                Button { run("get-ip") } label: {
                    Label("Copy device IP", systemImage: "globe")
                }
                .buttonStyle(.bordered)
                .disabled(state.targetSerials.isEmpty)
            }

            HubSection("Reverse port", subtitle: "Forward a device port to your Mac — e.g. Metro on 8081.") {
                HStack(spacing: 10) {
                    TextField("", text: $reversePort, prompt: Text("8081"))
                        .brandField()
                        .labelsHidden()
                        .frame(maxWidth: 140)
                    Button("Forward") {
                        run("reverse-port", ["port": .string(reversePort.trimmingCharacters(in: .whitespaces))])
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.targetSerials.isEmpty || reversePort.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            PrivateDnsSection()
            WirelessAdbSection()
        }
    }

    private func run(_ id: String, _ params: [String: FeatureValue] = [:]) {
        guard let feature = FeatureRegistry.byID[id] else { return }
        Task { await state.run(feature: feature, params: params) }
    }
}
