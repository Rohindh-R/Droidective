import ADBKit
import AppKit
import SwiftUI

/// Persistent record of a feature's last run — toasts disappear, this stays.
struct LastResultCard: View {
    @Environment(AppState.self) private var state
    let featureID: String

    var body: some View {
        if let entry = state.lastResults[featureID] {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: entry.result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(entry.result.ok ? .brandAccent : .red)
                    Text(entry.result.message)
                        .textSelection(.enabled)
                    Spacer()
                    Text(entry.at, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    if let copyText = entry.result.copyText {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(copyText, forType: .string)
                        }
                        .controlSize(.small)
                    }
                    if let revealPath = entry.result.revealPath {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealPath)])
                        }
                        .controlSize(.small)
                    }
                    if entry.result.needsAdbKeyboard {
                        Button("Install ADBKeyboard") {
                            state.installAdbKeyboard()
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 460, alignment: .leading)
            .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.borderSubtle, lineWidth: 1)
            )
        }
    }
}
