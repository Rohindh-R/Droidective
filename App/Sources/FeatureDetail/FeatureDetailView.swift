import ADBKit
import SwiftUI

/// Routes the selected feature to its detail pane by kind.
struct FeatureDetailView: View {
    @Environment(AppState.self) private var state
    let featureID: String?

    var body: some View {
        if featureID == "catalog" {
            CatalogView()
                .navigationTitle("Feature Catalog")
        } else if let featureID, let feature = FeatureRegistry.byID[featureID] {
            detail(for: feature)
                .navigationTitle(feature.title)
                .toolbar {
                    if let note = FeatureRegistry.howTo(for: feature.id) {
                        ToolbarItem(placement: .automatic) {
                            FeatureHelpButton(note: note)
                        }
                    }
                }
        } else if state.devices.isEmpty {
            DeviceSetupCard()
        } else {
            ContentUnavailableView(
                "Select a feature",
                systemImage: "square.grid.2x2",
                description: Text("Pick an action from the list, or press ⌘K to search.")
            )
        }
    }

    @ViewBuilder
    private func detail(for feature: FeatureDef) -> some View {
        if feature.id == "screenshot" {
            ScreenshotView()
        } else {
            detailByKind(for: feature)
        }
    }

    @ViewBuilder
    private func detailByKind(for feature: FeatureDef) -> some View {
        switch feature.kind {
        case .view, .system:
            switch feature.id {
            case "app-management":
                AppManagementView()
            case "deep-link":
                DeepLinksView()
            case "logcat":
                LogcatView()
            case "permissions":
                PermissionsView()
            case "app-info":
                AppInfoView()
            case "meminfo":
                MeminfoView()
            case "sandbox-browser":
                SandboxBrowserView()
            case "device-info":
                DeviceInfoView()
            case "screen-record":
                ScreenRecordView()
            case "crash-catcher":
                CrashView()
            case "wireless-adb":
                WirelessAdbView()
            case "custom-commands":
                CustomCommandsView()
            case "file-explorer":
                FileExplorerView()
            case "apps":
                AppsExplorerView()
            case "emulators":
                EmulatorsView()
            default:
                ComingSoonView(feature: feature)
            }
        case .instantAction:
            if FeatureEngine.implementedIDs.contains(feature.id) {
                InstantActionView(feature: feature)
            } else {
                ComingSoonView(feature: feature)
            }
        case .formAction:
            if FeatureEngine.implementedIDs.contains(feature.id) {
                FormActionView(feature: feature)
            } else {
                ComingSoonView(feature: feature)
            }
        case .toggleAction:
            if FeatureEngine.implementedIDs.contains(feature.id) {
                ToggleActionView(feature: feature)
            } else {
                ComingSoonView(feature: feature)
            }
        }
    }
}

/// ⓘ in the toolbar: what the feature does and how, in two sentences.
struct FeatureHelpButton: View {
    let note: String
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .help("How this feature works")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(.init(note))
                .font(.callout)
                .padding(14)
                .frame(width: 340)
        }
    }
}

struct ComingSoonView: View {
    let feature: FeatureDef

    var body: some View {
        ContentUnavailableView(
            feature.title,
            systemImage: feature.icon,
            description: Text("\(feature.subtitle ?? "")\n\nThis feature arrives in a later milestone.")
        )
    }
}
