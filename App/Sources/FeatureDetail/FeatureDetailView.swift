import ADBKit
import SwiftUI

/// Routes the selected feature to its detail pane by kind.
struct FeatureDetailView: View {
    @Environment(AppState.self) private var state
    @AppStorage("showFeatureNotes") private var showFeatureNotes = false
    let featureID: String?

    var body: some View {
        if featureID == "home" {
            HomeView()
        } else if featureID == "about" {
            AboutView()
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
            if showFeatureNotes, let note = FeatureRegistry.howTo(for: feature.id) {
                FeatureDescription(note: note)
            }
            if !hidesCommandBar(feature.id) {
                FeatureCommandBar(feature: feature)
            }
        }
    }

    /// Full-pane editor/recorder features manage their own actions and need the
    /// whole pane, so the command bar is hidden for them.
    private func hidesCommandBar(_ id: String) -> Bool {
        id == "video-editor" || id == "screen-record"
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
            case "react-native":
                ReactNativeView()
            case "simulate":
                SimulateView()
            case "connection":
                NetworkConnectionView()
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
            case "root-status":
                RootStatusView()
            case "wifi":
                WiFiView()
            case "private-dns":
                PrivateDnsView()
            case "system-restrictions":
                SystemRestrictionsView()
            case "screen-record":
                ScreenRecordView()
            case "video-editor":
                VideoEditorView()
            case "crash-catcher":
                CrashView()
            case "bug-report":
                BugReportView()
            case "wireless-adb":
                WirelessAdbView()
            case "custom-commands":
                CustomCommandsView()
            case "file-explorer":
                FileExplorerView()
            case "apps":
                AppsExplorerView()
            case "install-app":
                InstallAppView()
            case "emulators":
                EmulatorsView()
            case "performance":
                PerformanceView()
            case "network-speed":
                NetworkView()
            case "scrcpy":
                ScreenMirrorView()
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
    @AppStorage("showFeatureNotes") private var showFeatureNotes = false
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.textMuted)
            Text(.init(note))
                .font(.callout)
                .foregroundStyle(.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showFeatureNotes = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Hide this note (toggle back with ⓘ in the bar below)")
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
