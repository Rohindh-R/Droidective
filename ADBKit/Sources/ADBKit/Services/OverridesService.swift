import Foundation

public struct ActiveOverride: Sendable, Equatable, Identifiable {
    public let kind: OverrideKind
    public let value: String
    public let setAt: Double

    public var id: String { kind.rawValue }
}

extension OverrideKind {
    public var label: String {
        switch self {
        case .proxy: return "HTTP Proxy"
        case .layout: return "Font & Density"
        case .battery: return "Fake Battery"
        case .demo: return "Demo Mode"
        case .animation: return "Animations"
        case .locale: return "Locale"
        case .darkMode: return "Dark Mode"
        }
    }
}

/// Device-state overrides: apply a change, record it, reset it, and
/// reconcile the active set against the device so the UI pill is truthful.
///
/// Device-verifiable kinds (proxy / layout / animation / darkMode) are read
/// back from the device; battery / demo / locale can't be reliably read, so
/// they're trusted from the stored file.
public struct OverridesService: Sendable {
    static let animationSettings = [
        "window_animation_scale",
        "transition_animation_scale",
        "animator_duration_scale",
    ]
    static let demoIntent = "com.android.systemui.demo"

    let client: AdbClient
    let store: JSONStore<OverridesMap>

    public init(client: AdbClient, store: JSONStore<OverridesMap>) {
        self.client = client
        self.store = store
    }

    // MARK: - Apply

    public func applyProxy(serial: String, proxy: String) async throws(AdbError) -> String {
        _ = try await client.run(on: serial, ["shell", "settings", "put", "global", "http_proxy", shellQuote(proxy)])
        await record(serial: serial, kind: .proxy, value: proxy)
        return proxy
    }

    public func applyLayout(serial: String, fontScale: Double, density: Int?) async throws(AdbError) -> String {
        let scale = String(format: "%.2f", fontScale)
        _ = try await client.run(on: serial, ["shell", "settings", "put", "system", "font_scale", scale])
        if let density, density > 0 {
            _ = try await client.run(on: serial, ["shell", "wm", "density", String(density)])
        }
        let value = density.map { "font \(fontScale)× · \($0)dpi" } ?? "font \(fontScale)×"
        await record(serial: serial, kind: .layout, value: value)
        return value
    }

    public func applyBattery(serial: String, level: Int, unplugged: Bool) async throws(AdbError) -> String {
        _ = try await client.run(on: serial, ["shell", "dumpsys", "battery", "set", "level", String(level)])
        if unplugged {
            _ = try await client.run(on: serial, ["shell", "dumpsys", "battery", "unplug"])
        }
        let value = "\(level)%\(unplugged ? " · unplugged" : "")"
        await record(serial: serial, kind: .battery, value: value)
        return value
    }

    public func applyDarkMode(serial: String, on: Bool) async throws(AdbError) {
        _ = try await client.run(on: serial, ["shell", "cmd", "uimode", "night", on ? "yes" : "no"])
        if on {
            await record(serial: serial, kind: .darkMode, value: "Dark")
        } else {
            await forget(serial: serial, kind: .darkMode)
        }
    }

    public func applyAnimation(serial: String, off: Bool) async throws(AdbError) {
        let scale = off ? "0" : "1"
        for setting in Self.animationSettings {
            _ = try await client.run(on: serial, ["shell", "settings", "put", "global", setting, scale])
        }
        if off {
            await record(serial: serial, kind: .animation, value: "0× (off)")
        } else {
            await forget(serial: serial, kind: .animation)
        }
    }

    /// Best-effort: reliable locale change generally needs root/reboot. Try
    /// the broadcast path many ROMs honor; record so the user can reset.
    public func applyLocale(serial: String, locale: String) async throws(AdbError) -> String {
        _ = try await client.run(on: serial, [
            "shell", "am", "broadcast", "-a", "android.intent.action.LOCALE_CHANGED", "--es", "locale", shellQuote(locale),
        ])
        await record(serial: serial, kind: .locale, value: locale)
        return locale
    }

    public func applyDemo(serial: String, on: Bool) async throws(AdbError) {
        if on {
            _ = try await client.run(on: serial, ["shell", "settings", "put", "global", "sysui_demo_allowed", "1"])
            let broadcasts: [[String]] = [
                ["-e", "command", "enter"],
                ["-e", "command", "clock", "-e", "hhmm", "0941"],
                ["-e", "command", "battery", "-e", "level", "100", "-e", "plugged", "false"],
                ["-e", "command", "network", "-e", "wifi", "show", "-e", "level", "4"],
                ["-e", "command", "notifications", "-e", "visible", "false"],
            ]
            for extra in broadcasts {
                _ = try await client.run(on: serial, ["shell", "am", "broadcast", "-a", Self.demoIntent] + extra)
            }
            await record(serial: serial, kind: .demo, value: "on")
        } else {
            _ = try await client.run(on: serial, ["shell", "am", "broadcast", "-a", Self.demoIntent, "-e", "command", "exit"])
            await forget(serial: serial, kind: .demo)
        }
    }

    // MARK: - Reset

    public func reset(serial: String, kind: OverrideKind) async throws(AdbError) {
        switch kind {
        case .proxy:
            _ = try await client.run(on: serial, ["shell", "settings", "put", "global", "http_proxy", ":0"])
            _ = try await client.run(on: serial, ["shell", "settings", "delete", "global", "http_proxy"])
        case .layout:
            _ = try await client.run(on: serial, ["shell", "settings", "put", "system", "font_scale", "1.0"])
            _ = try await client.run(on: serial, ["shell", "wm", "density", "reset"])
        case .battery:
            _ = try await client.run(on: serial, ["shell", "dumpsys", "battery", "reset"])
        case .animation:
            for setting in Self.animationSettings {
                _ = try await client.run(on: serial, ["shell", "settings", "put", "global", setting, "1"])
            }
        case .darkMode:
            _ = try await client.run(on: serial, ["shell", "cmd", "uimode", "night", "no"])
        case .demo:
            _ = try await client.run(on: serial, ["shell", "am", "broadcast", "-a", Self.demoIntent, "-e", "command", "exit"])
        case .locale:
            break // No reliable non-root reset; just clear our record.
        }
        await forget(serial: serial, kind: kind)
    }

    public func resetAll(serial: String) async throws(AdbError) {
        for override in try await active(serial: serial) {
            try await reset(serial: serial, kind: override.kind)
        }
    }

    // MARK: - Reconcile

    /// The set of overrides actually in effect, verified against the device
    /// where possible.
    public func active(serial: String) async throws(AdbError) -> [ActiveOverride] {
        let stored = await store.load()[serial] ?? [:]
        let now = Date().timeIntervalSince1970 * 1000
        var active: [ActiveOverride] = []
        func setAt(_ kind: OverrideKind) -> Double {
            stored[kind.rawValue]?.setAt ?? now
        }

        let proxy = try await getSetting(serial: serial, namespace: "global", key: "http_proxy")
        if !proxy.isEmpty && proxy != "null" && proxy != ":0" {
            active.append(ActiveOverride(kind: .proxy, value: proxy, setAt: setAt(.proxy)))
        }

        let font = try await getSetting(serial: serial, namespace: "system", key: "font_scale")
        let densityOut = try await client.run(on: serial, ["shell", "wm", "density"]).stdout
        let densityOverride = densityOut.firstMatch(of: /Override density:\s*(\d+)/).map { String($0.1) }
        let fontActive = !font.isEmpty && font != "null" && font != "1.0" && font != "1"
        if fontActive || densityOverride != nil {
            var parts: [String] = []
            if fontActive { parts.append("font \(font)×") }
            if let densityOverride { parts.append("\(densityOverride)dpi") }
            active.append(ActiveOverride(kind: .layout, value: parts.joined(separator: " · "), setAt: setAt(.layout)))
        }

        let animation = try await getSetting(serial: serial, namespace: "global", key: "window_animation_scale")
        if animation == "0" || animation == "0.0" {
            active.append(ActiveOverride(kind: .animation, value: "0× (off)", setAt: setAt(.animation)))
        }

        let night = try await client.run(on: serial, ["shell", "cmd", "uimode", "night"]).stdout
        if night.range(of: #"\byes\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            active.append(ActiveOverride(kind: .darkMode, value: "Dark", setAt: setAt(.darkMode)))
        }

        for kind in [OverrideKind.battery, .demo, .locale] {
            if let entry = stored[kind.rawValue] {
                active.append(ActiveOverride(kind: kind, value: entry.value, setAt: entry.setAt))
            }
        }

        return active.sorted { $0.setAt < $1.setAt }
    }

    // MARK: - Helpers

    private func getSetting(serial: String, namespace: String, key: String) async throws(AdbError) -> String {
        try await client.run(on: serial, ["shell", "settings", "get", namespace, key])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func record(serial: String, kind: OverrideKind, value: String) async {
        _ = try? await store.update { map in
            var device = map[serial] ?? [:]
            device[kind.rawValue] = OverrideEntry(value: value, setAt: Date().timeIntervalSince1970 * 1000)
            map[serial] = device
        }
    }

    private func forget(serial: String, kind: OverrideKind) async {
        _ = try? await store.update { map in
            var device = map[serial] ?? [:]
            device[kind.rawValue] = nil
            map[serial] = device
        }
    }
}
