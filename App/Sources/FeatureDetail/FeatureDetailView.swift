import ADBKit
import SwiftUI

/// Routes the selected feature to its detail pane by kind.
struct FeatureDetailView: View {
    @Environment(AppState.self) private var state
    let featureID: String?

    var body: some View {
        if featureID == "home" {
            HomeView()
        } else if featureID == "catalog" {
            CatalogView()
                .navigationTitle("Feature Catalog")
        } else if let featureID, let feature = FeatureRegistry.byID[featureID] {
            featureBody(for: feature)
                .navigationTitle(feature.title)
        } else {
            HomeView()
        }
    }

    /// Every feature shows its "how it works" description beneath its content,
    /// then a command bar with the adb commands + executed output — both
    /// pinned below the feature's own (often centered) content so they never
    /// shift or clip it.
    private func featureBody(for feature: FeatureDef) -> some View {
        VStack(spacing: 0) {
            detail(for: feature)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let note = FeatureRegistry.howTo(for: feature.id) {
                FeatureDescription(note: note)
            }
            FeatureCommandBar(feature: feature)
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
            case "performance":
                PerformanceView()
            case "network-speed":
                NetworkView()
            case "scrcpy":
                ScrcpyView()
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

/// The feature's "how it works" note, rendered as a description strip beneath
/// the feature's content (above the command bar) — replaces the old ⓘ popover.
struct FeatureDescription: View {
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(.init(note))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
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
