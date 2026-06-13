import ADBKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarPaletteView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            FeatureDetailView(featureID: state.selectedFeatureID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        DeviceBarView()
                        if let operation = state.runningOperation {
                            OperationProgressStrip(operation: operation)
                        }
                    }
                }
        }
        .overlay(alignment: .bottom) {
            ToastOverlay()
        }
        .onAppear {
            state.openMainWindow = { openWindow(id: "main") }
            state.openPalette = { openWindow(id: "palette") }
            applyStoredTheme()
        }
    }
}

/// Progress strip pinned under the device bar: a real percentage bar when
/// the transfer size is known, a spinner otherwise.
struct OperationProgressStrip: View {
    let operation: AppState.OperationStatus

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = operation.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text("\(Int(fraction * 100))%")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(operation.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
