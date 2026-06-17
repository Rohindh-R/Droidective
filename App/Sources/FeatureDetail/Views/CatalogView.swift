import ADBKit
import SwiftUI

/// Feature catalog: enable/disable features, star favorites, restore the
/// out-of-box default set.
struct CatalogView: View {
    @Environment(AppState.self) private var state
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Default set")
                        Text("Bring back the \(FeatureRegistry.defaultEnabledIDs.count) features that are visible out of the box.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore defaults") {
                        confirmReset = true
                    }
                }
            }

            ForEach(FeatureCategory.displayOrder, id: \.self) { category in
                let features = FeatureRegistry.all.filter { $0.category == category }
                if !features.isEmpty {
                    Section(category.label) {
                        ForEach(features) { feature in
                            row(feature)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Restore the default feature set? Your pinned features are kept; enabled/disabled choices reset.",
            isPresented: $confirmReset
        ) {
            Button("Restore Defaults") {
                state.restoreDefaultFeatures()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ feature: FeatureDef) -> some View {
        HStack(spacing: 10) {
            Image(systemName: feature.icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(feature.title)
                if let subtitle = feature.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                state.toggleFavorite(feature.id)
            } label: {
                Image(systemName: state.layout.favorites.contains(feature.id) ? "pin.fill" : "pin")
                    .foregroundStyle(state.layout.favorites.contains(feature.id) ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help("Pin to top")

            Toggle("", isOn: Binding(
                get: { state.layout.effectiveEnabledIDs.contains(feature.id) },
                set: { state.setFeatureEnabled(feature.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(feature.kind == .system)
        }
        .padding(.vertical, 2)
    }
}
