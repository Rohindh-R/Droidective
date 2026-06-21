import ADBKit
import SwiftUI

/// Saved deep links for the selected bundle, as a `Form` section so it composes
/// into both the standalone screen and the React Native hub (and scrolls with
/// the rest of the form).
struct DeepLinksSection: View {
    @Environment(AppState.self) private var state
    @State private var links: [DeepLink] = []
    @State private var editingLink: DeepLink?
    @State private var showEditor = false
    @State private var draftLabel = ""
    @State private var draftURL = ""

    var body: some View {
        Section("Deep links") {
            if state.selectedBundle == nil {
                Text("Select a bundle in the bar above — deep links are saved per app.")
                    .foregroundStyle(.textMuted)
            } else {
                if links.isEmpty {
                    Text("No deep links yet. Add one like myapp://orders/123 to launch it in a click.")
                        .foregroundStyle(.textMuted)
                }
                ForEach(links) { link in
                    HStack {
                        Image(systemName: "link").foregroundStyle(.textMuted)
                        VStack(alignment: .leading) {
                            if !link.label.isEmpty { Text(link.label) }
                            Text(link.url)
                                .font(.footnote)
                                .foregroundStyle(.textMuted)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button { launch(link) } label: {
                            Image(systemName: "play.fill").foregroundStyle(.brandAccent)
                        }
                        .buttonStyle(.borderless)
                        .help("Launch on device")
                        Button {
                            editingLink = link
                            draftLabel = link.label
                            draftURL = link.url
                            showEditor = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        Button { remove(link) } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    editingLink = nil
                    draftLabel = ""
                    draftURL = ""
                    showEditor = true
                } label: {
                    Label("Add deep link", systemImage: "plus")
                }
            }
        }
        .task(id: state.selectedBundleId) { await loadLinks() }
        .sheet(isPresented: $showEditor) { editor }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingLink == nil ? "Add Deep Link" : "Edit Deep Link")
                .font(.headline)
            TextField("URL (e.g. myapp://orders/123)", text: $draftURL)
            TextField("Label (optional)", text: $draftLabel)
            HStack {
                Spacer()
                Button("Cancel") { showEditor = false }
                Button("Save") {
                    save()
                    showEditor = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func loadLinks() async {
        guard let bundleId = state.selectedBundleId else {
            links = []
            return
        }
        let map = await state.env.stores.deepLinks.load()
        links = map[bundleId] ?? []
    }

    private func persist() {
        guard let bundleId = state.selectedBundleId else { return }
        let snapshot = links
        Task {
            try? await state.env.stores.deepLinks.update { $0[bundleId] = snapshot }
        }
    }

    private func save() {
        let url = draftURL.trimmingCharacters(in: .whitespaces)
        let label = draftLabel.trimmingCharacters(in: .whitespaces)
        if var link = editingLink, let index = links.firstIndex(where: { $0.id == link.id }) {
            link.url = url
            link.label = label
            links[index] = link
        } else {
            links.append(DeepLink(label: label, url: url, createdAt: Date().timeIntervalSince1970 * 1000))
        }
        persist()
    }

    private func remove(_ link: DeepLink) {
        links.removeAll { $0.id == link.id }
        persist()
    }

    private func launch(_ link: DeepLink) {
        let targets = state.targetSerials
        guard !targets.isEmpty else {
            state.showToast(Toast(message: "No device connected.", ok: false))
            return
        }
        Task {
            await CommandLog.userInitiated(feature: "deep-link") {
                for serial in targets {
                    let result = (try? await state.env.engine.appControl.launchDeepLink(serial: serial, url: link.url))
                        ?? FeatureResult(ok: false, message: "adb not found")
                    state.showToast(Toast(message: result.message, ok: result.ok))
                }
            }
        }
    }
}

/// Standalone Deep Links screen — the section on its own in a grouped form.
struct DeepLinksView: View {
    var body: some View {
        Form {
            DeepLinksSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .centeredColumn()
    }
}
