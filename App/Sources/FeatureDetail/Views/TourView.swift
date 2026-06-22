import AppKit
import SwiftUI

/// A short paged walkthrough shown once on first launch (and replayable from
/// Home). Each step explains one part of the app; finishing or skipping marks
/// the tour seen so it won't reappear.
struct TourView: View {
    @Environment(AppState.self) private var state
    @AppStorage("hasSeenTour") private var hasSeenTour = false
    @State private var index = 0

    private struct Step {
        let icon: String
        let title: String
        let body: String
        let shortcut: String?
    }

    private let steps: [Step] = [
        Step(icon: "iphone.gen3", title: "Welcome to Droidective",
             body: "Your command center for debugging Android and React Native apps over adb. Here's a 30-second tour.",
             shortcut: nil),
        Step(icon: "magnifyingglass", title: "Find anything fast",
             body: "Press the shortcut from anywhere to search every feature and jump straight to one.",
             shortcut: "⌘K"),
        Step(icon: "sidebar.left", title: "Your feature sidebar",
             body: "Features are grouped by category — toggle grouping off to drag them into your own order. Right-click any one to pin, enable, or disable it. With the search field focused, hold ⌘ to jump to a row with ⌘1–⌘9. The shortcut hides the sidebar.",
             shortcut: "⌘B"),
        Step(icon: "iphone.badge.play", title: "The device bar",
             body: "The bar up top shows the connected device and selected app bundle. It stays put as you move between features.",
             shortcut: nil),
        Step(icon: "chevron.up.square", title: "Commands, Recent & Terminal",
             body: "Every feature has a bottom bar with the exact adb commands it runs, your recent runs and their output, and a real embedded terminal. The shortcut minimizes it.",
             shortcut: "⌘J"),
        Step(icon: "chart.line.uptrend.xyaxis", title: "Monitor performance",
             body: "Performance Monitor charts per-core CPU, RAM, FPS, and per-process usage live; Network Speed tracks download/upload. Record a session and export it to JSON or CSV.",
             shortcut: nil),
        Step(icon: "checkmark.seal", title: "You're all set",
             body: "Open the Feature Catalog to switch on more tools, and Settings for theme and the setup Doctor. ⌘= / ⌘- zoom the whole UI. Revisit this tour anytime from Home.",
             shortcut: "⌘,"),
    ]

    private var isLast: Bool { index == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            controls
        }
        .frame(width: 540, height: 440)
    }

    private var content: some View {
        let step = steps[index]
        return VStack(spacing: 18) {
            Image(systemName: step.icon)
                .font(.system(size: 54))
                .foregroundStyle(.brandAccent)
                .symbolRenderingMode(.hierarchical)
            Text(step.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            if let shortcut = step.shortcut {
                Text(shortcut)
                    .font(.title3.weight(.semibold))
                    .monospaced()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 8))
            }
            Text(step.body)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.textMuted)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var controls: some View {
        HStack {
            Button("Skip") { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(.textMuted)
                .opacity(isLast ? 0 : 1)

            Spacer()

            HStack(spacing: 7) {
                ForEach(steps.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? AnyShapeStyle(.brandAccent) : AnyShapeStyle(.borderSubtle))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if index > 0 {
                    Button("Back") { withAnimation { index -= 1 } }
                }
                Button(isLast ? "Get Started" : "Next") {
                    if isLast {
                        finish()
                    } else {
                        withAnimation { index += 1 }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func finish() {
        hasSeenTour = true
        state.presentTour = false
    }
}
