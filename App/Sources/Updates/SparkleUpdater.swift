#if !APPSTORE
import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle's updater and republishes whether a manual check is currently
/// allowed, so the "Check for Updates…" command can enable/disable itself.
///
/// Lives in the App layer (never ADBKit) and is compiled out of any Mac App
/// Store build, which updates through the App Store instead.
@MainActor
final class UpdaterViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    /// nil until a real EdDSA public key is embedded — without one, starting the
    /// updater fails its launch check and pops an error alert, so we hold off.
    private let controller: SPUStandardUpdaterController?

    init() {
        guard Self.signingKeyConfigured else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// True once `generate_keys`' output has replaced the project.yml placeholder.
    private static var signingKeyConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty && key != "REPLACE_WITH_OUTPUT_OF_generate_keys"
    }
}

/// App-wide updater. A single Sparkle controller must own update scheduling, so
/// the menu, About view, and Settings all share this one instance.
enum SparkleUpdater {
    @MainActor static let shared = UpdaterViewModel()
}

/// The "Check for Updates…" menu command, greyed out while a check is in flight.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
#endif
