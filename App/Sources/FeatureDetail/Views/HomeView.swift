import ADBKit
import AppKit
import SwiftUI

/// The landing screen: what Droidective is, the keyboard shortcuts that drive
/// it, how to customize features and theme, and an overview of every feature
/// category. Doubles as the no-device onboarding when nothing is connected.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if state.devices.isEmpty {
                    connectCard
                }
                shortcutsSection
                customizeSection
                categoriesSection
                tourFooter
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            Image(colorScheme == .dark ? "AppLogoDark" : "AppLogoLight")
                .resizable()
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Droidective")
                    .font(.largeTitle.bold())
                Text("An Android & React Native debugging command palette, driven over adb.")
                    .font(.title3)
                    .foregroundStyle(.textMuted)
            }
        }
    }

    // MARK: - Shortcuts

    private struct Shortcut: Identifiable {
        let id = UUID()
        let key: String
        let icon: String
        let title: String
        let detail: String
    }

    private static let shortcuts: [Shortcut] = [
        Shortcut(key: "⌘K", icon: "magnifyingglass", title: "Search features",
                 detail: "Open the palette and jump straight to any feature instantly."),
        Shortcut(key: "⌘B", icon: "sidebar.left", title: "Toggle sidebar",
                 detail: "Hide the feature list for more room, and bring it back anytime."),
        Shortcut(key: "⌘J", icon: "chevron.up.square", title: "Command bar",
                 detail: "Expand or minimize the Recent / Commands / Terminal bar beneath every feature."),
        Shortcut(key: "⌘,", icon: "gearshape", title: "Settings",
                 detail: "Theme, startup, hotkeys, and the setup Doctor that checks your toolchain."),
    ]

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Getting around")
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(Self.shortcuts) { shortcut in
                    shortcutCard(shortcut)
                }
            }
        }
    }

    private func shortcutCard(_ shortcut: Shortcut) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: shortcut.icon)
                .font(.title2)
                .foregroundStyle(.textMuted)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(shortcut.title).font(.headline)
                    KeyHint(shortcut.key)
                }
                Text(shortcut.detail)
                    .font(.callout)
                    .foregroundStyle(.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.borderSubtle, lineWidth: 1))
    }

    // MARK: - Customize

    private var customizeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Make it yours")

            infoRow(
                icon: "pin",
                title: "Enable, disable & pin features",
                detail: "Right-click any feature in the sidebar to pin it to the top, or enable/disable it. The Feature Catalog manages them all at once."
            ) {
                Button("Open Feature Catalog") { state.selectedFeatureID = "catalog" }
            }

            infoRow(
                icon: "paintbrush",
                title: "Theme",
                detail: "Match the system appearance, or force light or dark."
            ) {
                ThemePicker()
            }
        }
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("All \(FeatureRegistry.all.count) features")
            Text("Grouped into \(FeatureCategory.displayOrder.count) categories — browse and toggle every tool in the catalog.")
                .font(.callout)
                .foregroundStyle(.textMuted)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(FeatureCategory.displayOrder, id: \.self) { category in
                    categoryChip(category)
                }
            }
        }
    }

    private func categoryChip(_ category: FeatureCategory) -> some View {
        let count = FeatureRegistry.all.filter { $0.category == category }.count
        return HStack(spacing: 10) {
            Image(systemName: category.icon)
                .foregroundStyle(.textMuted)
                .frame(width: 22)
            Text(category.label)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.textMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.borderSubtle, lineWidth: 1))
    }

    // MARK: - Connect card (no device)

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("No device connected", systemImage: "iphone.gen3.badge.exclamationmark")
                .font(.headline)
            step(1, "On the device, open **Settings → About phone** and tap **Build number** 7 times to enable Developer options.")
            step(2, "In **Developer options**, turn on **USB debugging**.")
            step(3, "Plug in via USB and tap **Allow** on the debugging prompt — or connect over Wi-Fi.")
            HStack(spacing: 10) {
                Button { state.selectedFeatureID = "wireless-adb" } label: {
                    Label("Connect wirelessly", systemImage: "wifi")
                }
                Button { state.refreshDevices() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(.top, 2)
            if state.adbMissing {
                Label("adb isn't installed yet — use the Install button in the device bar first.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.brandAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .frame(width: 22, height: 22)
                .background(.brandAccent.opacity(0.15), in: Circle())
            Text(.init(text))
                .font(.callout)
                .foregroundStyle(.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var tourFooter: some View {
        HStack {
            Spacer()
            Button { state.presentTour = true } label: {
                Label("Replay the welcome tour", systemImage: "play.circle")
            }
            .buttonStyle(.link)
            Spacer()
        }
    }

    // MARK: - Building blocks

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title2.bold())
    }

    private func infoRow(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.textMuted)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.borderSubtle, lineWidth: 1))
    }
}

/// The Light / Dark / Auto segmented control, reused on Home and Settings.
struct ThemePicker: View {
    @AppStorage("theme") private var theme = "dark"

    var body: some View {
        Picker("", selection: $theme) {
            Text("Auto").tag("auto")
            Text("Light").tag("light")
            Text("Dark").tag("dark")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
        .onChange(of: theme) { applyStoredTheme() }
    }
}
