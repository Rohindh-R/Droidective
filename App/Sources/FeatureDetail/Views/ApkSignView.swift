import ADBKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Zipalign and sign an APK — with the embedded debug key for quick local
/// installs, or your own keystore for release builds. Passwords go to apksigner
/// through a private temp file, never the command line.
struct ApkSignView: View {
    @Environment(AppState.self) private var state
    @State private var inputURL: URL?
    @State private var useDebugKey = true
    @State private var keystoreURL: URL?
    @State private var storePassword = ""
    @State private var keyAlias = ""
    @State private var keyPassword = ""
    @State private var signing = false
    @State private var resultMessage: String?
    @State private var resultSchemes: [String] = []
    @State private var signedURL: URL?
    @State private var dropTargeted = false

    private var debugKeystore: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/debug.keystore")
    }

    private var canSign: Bool {
        guard inputURL != nil, !signing else { return false }
        return useDebugKey || (keystoreURL != nil && !storePassword.isEmpty)
    }

    var body: some View {
        Group {
            if inputURL == nil { dropZone } else { form }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "signature")
                .font(.system(size: 46))
                .foregroundStyle(.brandAccent)
            Text("Drag an APK here to sign")
                .font(.title3.weight(.medium))
            Button("Choose APK…") { choose() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bgSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    dropTargeted ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.borderSubtle),
                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [7])
                )
                .padding(24)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let apk = urls.first(where: { $0.pathExtension.lowercased() == "apk" }) else { return false }
            stage(apk)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section("APK") {
                LabeledContent("File", value: inputURL?.lastPathComponent ?? "")
                Button("Choose a different APK…") { choose() }
            }
            Section("Signing key") {
                Picker("Key", selection: $useDebugKey) {
                    Text("Debug key").tag(true)
                    Text("Keystore…").tag(false)
                }
                .pickerStyle(.radioGroup)
                if useDebugKey {
                    if !FileManager.default.fileExists(atPath: debugKeystore.path) {
                        Label(
                            "No debug keystore at ~/.android/debug.keystore yet — build any app once, or use your own keystore.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    keystoreFields
                }
            }
            Section {
                Button(signing ? "Signing…" : "Sign APK") { sign() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSign)
                if let resultMessage { resultRow(resultMessage) }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var keystoreFields: some View {
        LabeledContent("Keystore") {
            HStack {
                Text(keystoreURL?.lastPathComponent ?? "None").foregroundStyle(.textMuted)
                Button("Choose…") { chooseKeystore() }
            }
        }
        SecureField("Store password", text: $storePassword)
        TextField("Key alias (optional)", text: $keyAlias)
        SecureField("Key password (optional — defaults to store password)", text: $keyPassword)
    }

    @ViewBuilder private func resultRow(_ message: String) -> some View {
        if signedURL != nil {
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                if !resultSchemes.isEmpty {
                    Text("Verified: " + resultSchemes.map { $0.uppercased() }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.textMuted)
                }
                Button("Reveal in Finder") {
                    if let signedURL { NSWorkspace.shared.activateFileViewerSelecting([signedURL]) }
                }
            }
        } else {
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    // MARK: - Actions

    private func stage(_ url: URL) {
        inputURL = url
        resultMessage = nil
        signedURL = nil
        resultSchemes = []
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { stage(url) }
    }

    private func chooseKeystore() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { keystoreURL = panel.url }
    }

    private func sign() {
        guard let inputURL else { return }
        let output = inputURL.deletingPathExtension().path + "-signed.apk"
        let credentials: KeystoreCredentials
        if useDebugKey {
            credentials = .debug(keystorePath: debugKeystore.path)
        } else if let keystoreURL {
            credentials = KeystoreCredentials(
                keystorePath: keystoreURL.path, storePassword: storePassword,
                keyAlias: keyAlias.isEmpty ? nil : keyAlias,
                keyPassword: keyPassword.isEmpty ? nil : keyPassword)
        } else {
            return
        }
        signing = true
        Task {
            do {
                let result = try await state.env.engine.apkSigning.sign(
                    input: inputURL.path, output: output, credentials: credentials)
                resultSchemes = result.signature?.schemes ?? []
                signedURL = URL(fileURLWithPath: output)
                resultMessage = result.message
            } catch {
                resultMessage = error.localizedDescription
                signedURL = nil
            }
            signing = false
        }
    }
}
