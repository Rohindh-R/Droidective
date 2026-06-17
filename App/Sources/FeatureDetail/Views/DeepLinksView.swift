import ADBKit
import SwiftUI

/// Save deep links per bundle and launch them on the device.
struct DeepLinksView: View {
    @Environment(AppState.self) private var state
    @State private var links: [DeepLink] = []
    @State private var editingLink: DeepLink?
    @State private var showEditor = false
    @State private var draftLabel = ""
    @State private var draftURL = ""

    var body: some View {
        Group {
            if let bundle = state.selectedBundle {
                content(bundle: bundle)
            } else {
                ContentUnavailableView(
                    "No bundle selected",
                    systemImage: "link",
                    description: Text("Deep links are saved per app — select a bundle in the bar above.")
                )
            }
        }
        .task(id: state.selectedBundleId) { await loadLinks() }
    }

    private func content(bundle: AppBundle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Deep links for \(bundle.nickname)")
                    .font(.headline)
                Spacer()
                Button {
                    editingLink = nil
                    draftLabel = ""
                    draftURL = ""
                    showEditor = true
                } label: {
                    Label("Add Deep Link", systemImage: "plus")
                }
            }

            if links.isEmpty {
                ContentUnavailableView(
                    "No deep links saved",
                    systemImage: "link",
                    description: Text("Add a URL like myapp://orders/123 to launch it in one click.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(links) { link in
                    HStack {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            if !link.label.isEmpty {
                                Text(link.label)
                            }
                            Text(link.url)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            launch(link)
                        } label: {
                            Image(systemName: "play.fill").foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .help("Launch on device")
                        Button {
                            editingLink = link
                            draftLabel = link.label
                            draftURL = link.url
                            showEditor = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        Button {
                            remove(link)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
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
