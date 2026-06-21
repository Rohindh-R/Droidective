import ADBKit
import SwiftUI

/// Add, edit, and remove saved bundles; pick package ids straight from the
/// device's installed third-party apps.
struct BundleManagerView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var packageId = ""
    @State private var editingBundle: AppBundle?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Bundles")
                .font(.headline)

            if state.bundles.isEmpty {
                Text("Save an app's bundle id once, then pick it from dropdowns across the app.")
                    .font(.footnote)
                    .foregroundStyle(.textMuted)
            } else {
                List(state.bundles) { bundle in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(bundle.nickname)
                            Text(bundle.packageId)
                                .font(.footnote)
                                .foregroundStyle(.textMuted)
                        }
                        Spacer()
                        Button {
                            editingBundle = bundle
                            nickname = bundle.nickname
                            packageId = bundle.packageId
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        Button {
                            state.removeBundle(id: bundle.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minHeight: 120, maxHeight: 200)
            }

            Divider()

            Text(editingBundle == nil ? "Add new bundle" : "Edit bundle")
                .font(.subheadline.bold())
            TextField("Nickname (e.g. My App)", text: $nickname)
            TextField("Package id (e.g. com.myapp)", text: $packageId)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                if editingBundle != nil {
                    Button("Cancel Edit") {
                        editingBundle = nil
                        nickname = ""
                        packageId = ""
                    }
                }
                Button(editingBundle == nil ? "Add" : "Save") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(packageId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func submit() {
        let trimmedPackage = packageId.trimmingCharacters(in: .whitespaces)
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespaces)
        if var bundle = editingBundle {
            bundle.nickname = trimmedNickname.isEmpty ? trimmedPackage : trimmedNickname
            bundle.packageId = trimmedPackage
            state.updateBundle(bundle)
            state.selectBundle(bundle.id)
        } else {
            state.addBundle(nickname: trimmedNickname, packageId: trimmedPackage)
        }
        dismiss()
    }
}
