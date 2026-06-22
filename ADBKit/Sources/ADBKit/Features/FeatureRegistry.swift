import Foundation

/// The single declarative feature registry — a direct data port of the
/// reference app's `registry.ts`. Adding or rendering a feature is data, not
/// code, for everything except the bespoke `view`/`system` panels. Runner
/// implementations live in `FeatureEngine`, keyed by the same ids.
public enum FeatureRegistry {
    static let commonLocales: [FieldOption] = [
        FieldOption(value: "en-US", label: "English (US)"),
        FieldOption(value: "en-GB", label: "English (UK)"),
        FieldOption(value: "es-ES", label: "Spanish (Spain)"),
        FieldOption(value: "fr-FR", label: "French"),
        FieldOption(value: "de-DE", label: "German"),
        FieldOption(value: "ja-JP", label: "Japanese"),
        FieldOption(value: "ko-KR", label: "Korean"),
        FieldOption(value: "zh-CN", label: "Chinese (Simplified)"),
        FieldOption(value: "ar-EG", label: "Arabic (Egypt) — RTL"),
        FieldOption(value: "he-IL", label: "Hebrew — RTL"),
        FieldOption(value: "pt-BR", label: "Portuguese (Brazil)"),
        FieldOption(value: "hi-IN", label: "Hindi"),
    ]

    public static let all: [FeatureDef] = [
        // ── Input & Clipboard ────────────────────────────────────────────
        FeatureDef(
            id: "send-text", num: 1, title: "Send Text",
            subtitle: "Type text, URLs, or symbols on the device",
            keywords: ["type", "paste", "input", "keyboard", "url"],
            category: .input, icon: "keyboard", kind: .formAction,
            fields: [
                FieldDef(name: "text", label: "Text", control: .text, placeholder: "Text, URL, or special characters…")
            ]
        ),
        FeatureDef(
            id: "get-ip", num: 2, title: "Copy Device IP",
            subtitle: "Get the Wi-Fi IP address and copy it",
            keywords: ["ip", "address", "wifi", "network", "clipboard"],
            category: .connection, icon: "globe", kind: .instantAction
        ),

        // ── Connection ───────────────────────────────────────────────────
        FeatureDef(
            id: "connection", num: 49, title: "Connection",
            subtitle: "Copy IP, reverse port, disconnect, DNS & wireless setup",
            keywords: [
                "connection", "network", "reverse port", "reverse", "port", "8081",
                "forward", "tcp", "metro", "disconnect", "private dns", "dns", "dot",
                "dns-over-tls", "doh", "hostname", "resolver", "wireless", "wifi",
                "tcpip", "pair", "untethered", "adb connect", "connect",
            ],
            category: .connection, icon: "network", kind: .view, needsDevice: false
        ),
        FeatureDef(
            id: "reverse-port", num: 3, title: "Reverse Port",
            subtitle: "Forward a device port to your machine (Metro 8081)",
            keywords: ["reverse", "port", "8081", "metro", "tcp", "forward"],
            category: .connection, icon: "arrow.left.arrow.right", kind: .formAction,
            fields: [
                FieldDef(name: "port", label: "Port", control: .preset, presetKey: "reversePorts", placeholder: "8081")
            ]
        ),
        FeatureDef(
            id: "wireless-adb", num: 4, title: "Wireless ADB",
            subtitle: "Connect over Wi-Fi (tcpip + Android 11 pairing)",
            keywords: ["wireless", "wifi", "tcpip", "pair", "connect", "untethered"],
            category: .connection, icon: "wifi", kind: .view, needsDevice: false
        ),
        FeatureDef(
            id: "emulators", num: 40, title: "Emulators",
            subtitle: "List, launch, and stop Android emulators",
            keywords: ["emulator", "avd", "virtual", "simulator", "launch", "boot"],
            category: .connection, icon: "play.display", kind: .view, needsDevice: false
        ),
        FeatureDef(
            id: "network-speed", num: 41, title: "Network Speed",
            subtitle: "Live download & upload throughput with recording",
            keywords: [
                "network", "speed", "bandwidth", "throughput", "upload", "download",
                "data", "traffic", "rx", "tx", "wifi", "cellular", "mbps",
            ],
            category: .connection, icon: "speedometer", kind: .view
        ),
        FeatureDef(
            id: "wifi", num: 43, title: "Wi-Fi",
            subtitle: "Connection details, toggle, saved networks & passwords",
            keywords: [
                "wifi", "wi-fi", "wlan", "ssid", "password", "saved", "network",
                "connect", "switch", "toggle", "ssid", "credential", "wpa",
            ],
            category: .connection, icon: "wifi", kind: .view
        ),
        FeatureDef(
            id: "private-dns", num: 45, title: "Private DNS",
            subtitle: "Off, automatic, or a DNS-over-TLS provider",
            keywords: ["dns", "private dns", "dot", "dns-over-tls", "hostname", "resolver", "doh", "edit dns"],
            category: .connection, icon: "lock.shield", kind: .view
        ),

        // ── React Native ─────────────────────────────────────────────────
        FeatureDef(
            id: "react-native", num: 47, title: "React Native",
            subtitle: "Dev menu, reload, deep links, dev server, process death",
            keywords: [
                "react native", "rn", "metro", "expo", "dev menu", "reload",
                "deep link", "process death", "dev server", "hub", "shake",
                "refresh", "js", "bundle", "url", "intent", "scheme", "universal",
                "kill", "restore", "background", "dev host", "debug server",
            ],
            category: .reactNative, icon: "atom", kind: .view, needsDevice: false
        ),
        FeatureDef(
            id: "open-dev-menu", num: 7, title: "Open Dev Menu",
            subtitle: "Open the React Native developer menu",
            keywords: ["dev", "menu", "82", "react native", "shake"],
            category: .reactNative, icon: "filemenu.and.selection", kind: .instantAction
        ),
        FeatureDef(
            id: "reload-js", num: 8, title: "Reload JS",
            subtitle: "Reload the JS bundle (double-tap R)",
            keywords: ["reload", "refresh", "js", "bundle", "rr"],
            category: .reactNative, icon: "arrow.clockwise", kind: .instantAction
        ),
        FeatureDef(
            id: "deep-link", num: 10, title: "Deep Links",
            subtitle: "Launch and save deep links per app",
            keywords: ["deep link", "url", "intent", "scheme", "universal"],
            category: .reactNative, icon: "link", kind: .view, needsBundle: true
        ),
        FeatureDef(
            id: "process-death", num: 11, title: "Simulate Process Death",
            subtitle: "Background then kill the app to test restoration",
            keywords: ["process death", "kill", "restore", "state", "background"],
            category: .reactNative, icon: "xmark.octagon", kind: .instantAction, needsBundle: true
        ),
        FeatureDef(
            id: "rn-dev-host", num: 12, title: "Set Dev Server Host",
            subtitle: "Point the app at a different Metro host",
            keywords: ["dev host", "bundle host", "metro", "ip", "debug server"],
            category: .reactNative, icon: "network", kind: .formAction,
            fields: [
                FieldDef(name: "host", label: "Host (ip:port)", control: .text, placeholder: "192.168.1.10:8081")
            ]
        ),

        // ── Screen & Capture ─────────────────────────────────────────────
        FeatureDef(
            id: "scrcpy", num: 13, title: "Mirror Screen",
            subtitle: "Mirror and control the device with scrcpy",
            keywords: ["scrcpy", "mirror", "screen", "cast", "control", "record", "bitrate", "fps"],
            category: .screen, icon: "display", kind: .view, needsScrcpy: true
        ),
        FeatureDef(
            id: "screenshot", num: 14, title: "Screenshot",
            subtitle: "Capture the screen and save it to your Mac",
            keywords: ["screenshot", "capture", "screencap", "png", "image"],
            category: .screen, icon: "camera", kind: .instantAction
        ),
        FeatureDef(
            id: "screen-record", num: 15, title: "Screen Record",
            subtitle: "Record the screen, auto-pull, optional GIF",
            keywords: ["record", "video", "screenrecord", "gif", "capture"],
            category: .screen, icon: "video", kind: .view
        ),
        FeatureDef(
            id: "demo-mode", num: 16, title: "Demo Mode",
            subtitle: "Clean status bar for store screenshots",
            keywords: ["demo", "status bar", "clean", "screenshot", "store"],
            category: .screen, icon: "wand.and.stars", kind: .toggleAction,
            isStateOverride: true, overrideKind: .demo,
            toggleOnLabel: "Demo mode on", toggleOffLabel: "Demo mode off"
        ),

        // ── Device Info & State Simulation ───────────────────────────────
        FeatureDef(
            id: "file-explorer", num: 38, title: "File Explorer",
            subtitle: "Browse device storage — copy, move, delete, pull",
            keywords: ["files", "storage", "sdcard", "browse", "folder", "explorer", "copy", "paste"],
            category: .deviceState, icon: "externaldrive", kind: .view
        ),
        FeatureDef(
            id: "device-info", num: 17, title: "Device Info",
            subtitle: "Browse and search every device property",
            keywords: ["info", "getprop", "android version", "model", "serial", "ram"],
            category: .deviceState, icon: "info.circle", kind: .view
        ),
        FeatureDef(
            id: "root-status", num: 42, title: "Root Status",
            subtitle: "Check whether the device is rooted, and how",
            keywords: ["root", "rooted", "su", "magisk", "superuser", "selinux", "test-keys", "jailbreak"],
            category: .logs, icon: "checkmark.shield", kind: .view
        ),
        FeatureDef(
            id: "system-restrictions", num: 46, title: "System Restrictions",
            subtitle: "Dev toggles — verifier, hidden APIs, SELinux (root)",
            keywords: [
                "restriction", "bypass", "verifier", "package verifier", "hidden api",
                "selinux", "setenforce", "permissive", "remount", "stay awake", "adb install",
            ],
            category: .deviceState, icon: "lock.open", kind: .view
        ),
        FeatureDef(
            id: "simulate", num: 48, title: "Simulate",
            subtitle: "Fake battery, appearance, locale, network & proxy",
            keywords: [
                "simulate", "device state", "override", "battery", "fake", "unplugged",
                "charge", "dark mode", "dark", "light", "theme", "night", "animation",
                "scale", "speed", "locale", "language", "i18n", "rtl", "font",
                "font scale", "density", "dpi", "layout", "text size", "network",
                "wifi", "data", "airplane", "offline", "proxy", "charles", "proxyman",
                "mitmproxy", "http",
            ],
            category: .deviceState, icon: "slider.horizontal.3", kind: .view, needsDevice: false
        ),
        FeatureDef(
            id: "fake-battery", num: 18, title: "Fake Battery",
            subtitle: "Set a fake battery level and unplugged state",
            keywords: ["battery", "fake", "level", "unplugged", "charge"],
            category: .deviceState, icon: "battery.25percent", kind: .formAction,
            isStateOverride: true, overrideKind: .battery,
            fields: [
                FieldDef(
                    name: "level", label: "Battery level (%)", control: .slider,
                    defaultValue: .number(5), min: 0, max: 100, step: 1
                ),
                FieldDef(name: "unplugged", label: "Simulate unplugged", control: .switch, defaultValue: .bool(true)),
            ]
        ),
        FeatureDef(
            id: "dark-mode", num: 19, title: "Dark Mode",
            subtitle: "Toggle system dark mode",
            keywords: ["dark", "light", "theme", "night", "ui mode"],
            category: .deviceState, icon: "moon", kind: .toggleAction,
            isStateOverride: true, overrideKind: .darkMode,
            toggleOnLabel: "Dark", toggleOffLabel: "Light"
        ),
        FeatureDef(
            id: "layout-overrides", num: 20, title: "Font & Density",
            subtitle: "Override font scale and display density",
            keywords: ["font scale", "density", "dpi", "responsive", "layout", "text size"],
            category: .deviceState, icon: "ruler", kind: .formAction,
            isStateOverride: true, overrideKind: .layout,
            fields: [
                FieldDef(
                    name: "fontScale", label: "Font scale", control: .slider,
                    defaultValue: .number(1), min: 0.85, max: 1.3, step: 0.05
                ),
                FieldDef(
                    name: "density", label: "Density (dpi, blank = keep)", control: .number,
                    placeholder: "420", optional: true
                ),
            ]
        ),
        FeatureDef(
            id: "animation-scale", num: 21, title: "Animation Scale",
            subtitle: "Set animation scales to 0× or 1×",
            keywords: ["animation", "scale", "0x", "speed", "transition", "animator"],
            category: .deviceState, icon: "speedometer", kind: .toggleAction,
            isStateOverride: true, overrideKind: .animation,
            toggleOnLabel: "Animations off (0×)", toggleOffLabel: "Animations on (1×)"
        ),
        FeatureDef(
            id: "locale", num: 22, title: "Change Locale",
            subtitle: "Switch device language for i18n testing",
            keywords: ["locale", "language", "i18n", "rtl", "translation"],
            category: .deviceState, icon: "character.bubble", kind: .formAction,
            isStateOverride: true, overrideKind: .locale,
            fields: [
                FieldDef(
                    name: "locale", label: "Locale", control: .select,
                    options: commonLocales, defaultValue: .string("en-US")
                )
            ]
        ),
        FeatureDef(
            id: "network-toggles", num: 23, title: "Network Toggles",
            subtitle: "Toggle Wi-Fi, mobile data, and airplane mode",
            keywords: ["wifi", "data", "airplane", "network", "radio", "offline"],
            category: .deviceState, icon: "antenna.radiowaves.left.and.right", kind: .formAction,
            fields: [
                FieldDef(name: "wifi", label: "Wi-Fi", control: .switch, defaultValue: .bool(true)),
                FieldDef(name: "data", label: "Mobile data", control: .switch, defaultValue: .bool(true)),
                FieldDef(name: "airplane", label: "Airplane mode", control: .switch, defaultValue: .bool(false)),
            ]
        ),
        FeatureDef(
            id: "http-proxy", num: 24, title: "HTTP Proxy",
            subtitle: "Set or clear the global proxy (Charles, Proxyman)",
            keywords: ["proxy", "charles", "proxyman", "mitmproxy", "http", "debug"],
            category: .deviceState, icon: "point.3.connected.trianglepath.dotted", kind: .formAction,
            isStateOverride: true, overrideKind: .proxy,
            fields: [
                FieldDef(
                    name: "proxy", label: "Proxy (host:port)", control: .preset,
                    presetKey: "proxies", placeholder: "10.0.0.5:8888"
                )
            ]
        ),

        // ── App Management ───────────────────────────────────────────────
        FeatureDef(
            id: "apps", num: 39, title: "Apps",
            subtitle: "All installed & system apps — manage, permissions, info",
            keywords: [
                "apps", "applications", "packages", "installed", "system", "explore",
                "manage app", "manage", "open", "force stop", "clear data",
                "clear cache", "uninstall", "disable", "permissions", "permission",
                "grant", "revoke", "runtime", "app info", "version", "sdk", "apk", "size",
            ],
            category: .appManagement, icon: "square.grid.3x3", kind: .view
        ),
        FeatureDef(
            id: "app-management", num: 25, title: "Manage App",
            subtitle: "Open, stop, clear, or uninstall an app",
            keywords: ["open", "close", "force stop", "clear data", "uninstall", "cache"],
            category: .appManagement, icon: "macwindow", kind: .view, needsBundle: true
        ),
        FeatureDef(
            id: "permissions", num: 26, title: "Permissions",
            subtitle: "Grant or revoke runtime permissions",
            keywords: ["permission", "grant", "revoke", "runtime", "checklist"],
            category: .appManagement, icon: "checkmark.shield", kind: .view, needsBundle: true
        ),
        FeatureDef(
            id: "app-info", num: 27, title: "App Info",
            subtitle: "Version, target SDK, size — and pull the APK",
            keywords: ["version", "version code", "sdk", "apk", "install date", "size"],
            category: .appManagement, icon: "shippingbox", kind: .view, needsBundle: true
        ),
        FeatureDef(
            id: "current-activity", num: 28, title: "Copy Current Activity",
            subtitle: "Show the foreground Activity right now",
            keywords: ["activity", "foreground", "screen", "resumed", "dumpsys", "copy"],
            category: .appManagement, icon: "square.stack.3d.up", kind: .instantAction
        ),
        FeatureDef(
            id: "foreground-package", num: 37, title: "Copy Foreground Bundle ID",
            subtitle: "Get the package id of the app on screen now",
            keywords: ["package", "bundle id", "foreground", "current app", "which app"],
            category: .appManagement, icon: "scope", kind: .instantAction
        ),
        FeatureDef(
            id: "meminfo", num: 29, title: "Memory Usage",
            subtitle: "Live memory usage for an app",
            keywords: ["memory", "meminfo", "ram", "pss", "heap"],
            category: .appManagement, icon: "memorychip", kind: .view, needsBundle: true
        ),
        FeatureDef(
            id: "sandbox-browser", num: 30, title: "Sandbox Browser",
            subtitle: "Browse and pull app files (debug builds)",
            keywords: ["sandbox", "files", "run-as", "sqlite", "shared prefs", "mmkv"],
            category: .appManagement, icon: "folder", kind: .view, needsBundle: true
        ),
        FeatureDef(
            id: "monkey", num: 31, title: "Monkey Test",
            subtitle: "Fire random events to hunt for crashes",
            keywords: ["monkey", "stress", "random", "fuzz", "crash"],
            category: .appManagement, icon: "die.face.5", kind: .formAction, needsBundle: true,
            fields: [
                FieldDef(
                    name: "count", label: "Event count", control: .number,
                    defaultValue: .number(500), min: 1, max: 100_000
                )
            ]
        ),

        // ── Logs & Diagnostics ───────────────────────────────────────────
        FeatureDef(
            id: "logcat", num: 32, title: "Logcat",
            subtitle: "Live log stream with search and filters",
            keywords: ["logcat", "logs", "stream", "filter", "tag", "level"],
            category: .logs, icon: "scroll", kind: .view
        ),
        FeatureDef(
            id: "crash-catcher", num: 33, title: "Crash Catcher",
            subtitle: "Filtered crashes + copy-last-crash for Slack/Jira",
            keywords: ["crash", "fatal", "exception", "androidruntime", "reactnativejs"],
            category: .logs, icon: "exclamationmark.triangle", kind: .view
        ),
        FeatureDef(
            id: "bug-report", num: 34, title: "Bug Report",
            subtitle: "Zip screenshot + logs + device info + version",
            keywords: ["bug report", "zip", "bundle", "diagnostics", "export"],
            category: .logs, icon: "doc.zipper", kind: .instantAction
        ),
        FeatureDef(
            id: "performance", num: 35, title: "Performance Monitor",
            subtitle: "Live CPU, RAM & FPS with recording and export",
            keywords: [
                "performance", "perf", "cpu", "core", "ram", "memory", "fps",
                "frame", "jank", "profiler", "monitor", "gfxinfo", "graph",
                "network", "speed", "bandwidth", "throughput", "upload", "download",
            ],
            category: .logs, icon: "chart.line.uptrend.xyaxis", kind: .view
        ),

        // ── Tool UX (system) ─────────────────────────────────────────────
        FeatureDef(
            id: "custom-commands", num: 36, title: "Custom Commands",
            subtitle: "Define your own adb actions with {bundleId}",
            keywords: ["custom", "command", "palette", "adb", "macro", "shortcut"],
            category: .toolUX, icon: "terminal", kind: .system, needsDevice: false
        ),
    ]

    public static let byID: [String: FeatureDef] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    /// Every feature is enabled out of the box. Hub members are folded into
    /// their hub and never appear as standalone rows, so the default enabled
    /// set is exactly the catalog (non-absorbed) features.
    public static let defaultEnabledIDs: [String] = catalogFeatureIDs

    /// Always-available features (never hidden, not counted in "+N more").
    public static let systemFeatureIDs: [String] = all.filter { $0.kind == .system }.map(\.id)

    /// Hub screens and the individual features they gather. A hub member is
    /// managed from its hub screen — hidden from the catalog and sidebar (see
    /// `absorbedFeatureIDs`) — but stays searchable and hotkey-able.
    public static let absorbedByHub: [String: [String]] = [
        "react-native": ["open-dev-menu", "reload-js", "deep-link", "process-death", "rn-dev-host"],
        "simulate": [
            "fake-battery", "dark-mode", "layout-overrides", "animation-scale",
            "locale", "network-toggles", "http-proxy",
        ],
        "connection": ["reverse-port", "private-dns", "wireless-adb"],
        // The Apps explorer already shows per-app permissions, info, and
        // management, so the standalone per-bundle screens fold into it.
        "apps": ["app-management", "permissions", "app-info"],
    ]

    /// Flattened hub members — folded into a hub, so hidden from the catalog
    /// and sidebar. They remain in `all` (searchable + hotkey-able).
    public static let absorbedFeatureIDs: Set<String> = Set(absorbedByHub.values.flatMap { $0 })

    /// Features the user manages individually in the catalog and sidebar:
    /// everything except hub members. The hub screens themselves are included.
    public static let catalogFeatureIDs: [String] = all.map(\.id).filter { !absorbedFeatureIDs.contains($0) }
}

public extension FeatureDef {
    /// Whether this feature is folded into a hub. Hub members are managed from
    /// the hub screen — hidden from the catalog and sidebar — but stay
    /// searchable and hotkey-able. See `FeatureRegistry.absorbedByHub`.
    var isAbsorbedByHub: Bool { FeatureRegistry.absorbedFeatureIDs.contains(id) }
}
