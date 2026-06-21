import ADBKit
import SwiftUI

/// Pick an installed app: one click saves it as a bundle, selects it, and
/// closes — no extra confirmation step.
struct InstalledAppsPickerView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var packages: [String]?
    @State private var filter = ""
    @State private var includeSystem = false

    private var visiblePackages: [String] {
        guard let packages else { return [] }
        return filter.isEmpty
            ? packages
            : packages.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Installed apps")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(12)

            HStack(spacing: 10) {
                TextField("Filter…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle("System apps", isOn: $includeSystem)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            if let packages {
                if packages.isEmpty {
                    ContentUnavailableView(
                        "No apps found",
                        systemImage: "shippingbox",
                        description: Text(includeSystem
                            ? "Couldn't list packages on this device."
                            : "No user-installed apps — tick \"System apps\" to include them.")
                    )
                } else {
                    List(visiblePackages, id: \.self) { package in
                        Button {
                            pick(package)
                        } label: {
                            HStack {
                                Text(package)
                                Spacer()
                                if state.bundles.contains(where: { $0.packageId == package }) {
                                    Text("saved")
                                        .font(.caption)
                                        .foregroundStyle(.textMuted)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ProgressView("Reading installed apps…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 420, height: 380)
        .task(id: includeSystem) { await load() }
    }

    private func load() async {
        packages = nil
        guard let serial = state.targetSerials.first else {
            packages = []
            return
        }
        let result = (try? await state.env.engine.appControl.listInstalledPackages(
            serial: serial, includeSystem: includeSystem
        )) ?? []
        guard !Task.isCancelled else { return }
        packages = result
    }

    /// Selecting an app IS the confirmation: save (or reuse), select, close.
    private func pick(_ package: String) {
        if let existing = state.bundles.first(where: { $0.packageId == package }) {
            state.selectBundle(existing.id)
        } else {
            let nickname = package.split(separator: ".").last.map(String.init)?.capitalized ?? package
            state.addBundle(nickname: nickname, packageId: package)
        }
        dismiss()
    }
}
