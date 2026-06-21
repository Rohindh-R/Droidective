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
            category: .input, icon: "keyboard", kind: .formAction, defaultEnabled: true,
            fields: [
                FieldDef(name: "text", label: "Text", control: .text, placeholder: "Text, URL, or special characters…")
            ]
        ),
        FeatureDef(
            id: "get-ip", num: 2, title: "Copy Device IP",
            subtitle: "Get the Wi-Fi IP address and copy it",
            keywords: ["ip", "address", "wifi", "network", "clipboard"],
            category: .connection, icon: "globe", kind: .instantAction, defaultEnabled: true
        ),

        // ── Connection ───────────────────────────────────────────────────
        FeatureDef(
            id: "connection", num: 49, title: "Connection",
            subtitle: "Copy IP, reverse port, disconnect, DNS & wireless setup",
            keywords: [
                "connection", "network", "reverse port", "metro", "disconnect",
                "private dns", "dns", "wireless", "tcpip", "pair", "adb connect",
            ],
            category: .connection, icon: "network", kind: .view, defaultEnabled: true, needsDevice: false
        ),
        FeatureDef(
            id: "reverse-port", num: 3, title: "Reverse Port",
            subtitle: "Forward a device port to your machine (Metro 8081)",
            keywords: ["reverse", "port", "8081", "metro", "tcp", "forward"],
            category: .connection, icon: "arrow.left.arrow.right", kind: .formAction, defaultEnabled: false,
            fields: [
                FieldDef(name: "port", label: "Port", control: .preset, presetKey: "reversePorts", placeholder: "8081")
            ]
        ),
        FeatureDef(
            id: "wireless-adb", num: 4, title: "Wireless ADB",
            subtitle: "Connect over Wi-Fi (tcpip + Android 11 pairing)",
            keywords: ["wireless", "wifi", "tcpip", "pair", "connect", "untethered"],
            category: .connection, icon: "wifi", kind: .view, defaultEnabled: false, needsDevice: false
        ),
        FeatureDef(
            id: "disconnect", num: 5, title: "Disconnect",
            subtitle: "Drop a wireless adb connection",
            keywords: ["disconnect", "unplug", "wireless"],
            category: .connection, icon: "wifi.slash", kind: .formAction, defaultEnabled: false, needsDevice: false,
            fields: [
                FieldDef(
                    name: "target", label: "Target (ip:port)", control: .text,
                    placeholder: "Leave blank to disconnect all", optional: true
                )
            ]
        ),
        FeatureDef(
            id: "emulators", num: 40, title: "Emulators",
            subtitle: "List, launch, and stop Android emulators",
            keywords: ["emulator", "avd", "virtual", "simulator", "launch", "boot"],
            category: .connection, icon: "play.display", kind: .view, defaultEnabled: true, needsDevice: false
        ),
        FeatureDef(
            id: "network-speed", num: 41, title: "Network Speed",
            subtitle: "Live download & upload throughput with recording",
            keywords: [
                "network", "speed", "bandwidth", "throughput", "upload", "download",
                "data", "traffic", "rx", "tx", "wifi", "cellular", "mbps",
            ],
            category: .connection, icon: "speedometer", kind: .view, defaultEnabled: true
        ),
        FeatureDef(
            id: "wifi", num: 43, title: "Wi-Fi",
            subtitle: "Connection details, toggle, saved networks & passwords",
            keywords: [
                "wifi", "wi-fi", "wlan", "ssid", "password", "saved", "network",
                "connect", "switch", "toggle", "ssid", "credential", "wpa",
            ],
            category: .connection, icon: "wifi", kind: .view, defaultEnabled: true
        ),
        FeatureDef(
            id: "private-dns", num: 45, title: "Private DNS",
            subtitle: "Off, automatic, or a DNS-over-TLS provider",
            keywords: ["dns", "private dns", "dot", "dns-over-tls", "hostname", "resolver", "doh", "edit dns"],
            category: .connection, icon: "lock.shield", kind: .view, defaultEnabled: false
        ),

        // ── React Native ─────────────────────────────────────────────────
        FeatureDef(
            id: "react-native", num: 47, title: "React Native",
            subtitle: "Dev menu, reload, deep links, dev server, process death",
            keywords: [
                "react native", "rn", "metro", "expo", "dev menu", "reload",
                "deep link", "process death", "dev server", "hub",
            ],
            category: .reactNative, icon: "atom", kind: .view, defaultEnabled: true, needsDevice: false
        ),
        FeatureDef(
            id: "open-dev-menu", num: 7, title: "Open Dev Menu",
            subtitle: "Open the React Native developer menu",
            keywords: ["dev", "menu", "82", "react native", "shake"],
            category: .reactNative, icon: "filemenu.and.selection", kind: .instantAction, defaultEnabled: false
        ),
        FeatureDef(
            id: "reload-js", num: 8, title: "Reload JS",
            subtitle: "Reload the JS bundle (double-tap R)",
            keywords: ["reload", "refresh", "js", "bundle", "rr"],
            category: .reactNative, icon: "arrow.clockwise", kind: .instantAction, defaultEnabled: false
        ),
        FeatureDef(
            id: "deep-link", num: 10, title: "Deep Links",
            subtitle: "Launch and save deep links per app",
            keywords: ["deep link", "url", "intent", "scheme", "universal"],
            category: .reactNative, icon: "link", kind: .view, defaultEnabled: false, needsBundle: true
        ),
        FeatureDef(
            id: "process-death", num: 11, title: "Simulate Process Death",
            subtitle: "Background then kill the app to test restoration",
            keywords: ["process death", "kill", "restore", "state", "background"],
            category: .reactNative, icon: "xmark.octagon", kind: .instantAction, defaultEnabled: false, needsBundle: true
        ),
        FeatureDef(
            id: "rn-dev-host", num: 12, title: "Set Dev Server Host",
            subtitle: "Point the app at a different Metro host",
            keywords: ["dev host", "bundle host", "metro", "ip", "debug server"],
            category: .reactNative, icon: "network", kind: .formAction, defaultEnabled: false,
            fields: [
                FieldDef(name: "host", label: "Host (ip:port)", control: .text, placeholder: "192.168.1.10:8081")
            ]
        ),

        // ── Screen & Capture ─────────────────────────────────────────────
        FeatureDef(
            id: "scrcpy", num: 13, title: "Mirror Screen",
            subtitle: "Mirror and control the device with scrcpy",
            keywords: ["scrcpy", "mirror", "screen", "cast", "control", "record", "bitrate", "fps"],
            category: .screen, icon: "display", kind: .view, defaultEnabled: true, needsScrcpy: true
        ),
        FeatureDef(
            id: "screenshot", num: 14, title: "Screenshot",
            subtitle: "Capture the screen and save it to your Mac",
            keywords: ["screenshot", "capture", "screencap", "png", "image"],
            category: .screen, icon: "camera", kind: .instantAction, defaultEnabled: true
        ),
        FeatureDef(
            id: "screen-record", num: 15, title: "Screen Record",
            subtitle: "Record the screen, auto-pull, optional GIF",
            keywords: ["record", "video", "screenrecord", "gif", "capture"],
            category: .screen, icon: "video", kind: .view, defaultEnabled: false
        ),
        FeatureDef(
            id: "demo-mode", num: 16, title: "Demo Mode",
            subtitle: "Clean status bar for store screenshots",
            keywords: ["demo", "status bar", "clean", "screenshot", "store"],
            category: .screen, icon: "wand.and.stars", kind: .toggleAction, defaultEnabled: false,
            isStateOverride: true, overrideKind: .demo,
            toggleOnLabel: "Demo mode on", toggleOffLabel: "Demo mode off"
        ),

        // ── Device Info & State Simulation ───────────────────────────────
        FeatureDef(
            id: "file-explorer", num: 38, title: "File Explorer",
            subtitle: "Browse device storage — copy, move, delete, pull",
            keywords: ["files", "storage", "sdcard", "browse", "folder", "explorer", "copy", "paste"],
            category: .deviceState, icon: "externaldrive", kind: .view, defaultEnabled: true
        ),
        FeatureDef(
            id: "device-info", num: 17, title: "Device Info",
            subtitle: "Browse and search every device property",
            keywords: ["info", "getprop", "android version", "model", "serial", "ram"],
            category: .deviceState, icon: "info.circle", kind: .view, defaultEnabled: false
        ),
        FeatureDef(
            id: "root-status", num: 42, title: "Root Status",
            subtitle: "Check whether the device is rooted, and how",
            keywords: ["root", "rooted", "su", "magisk", "superuser", "selinux", "test-keys", "jailbreak"],
            category: .logs, icon: "checkmark.shield", kind: .view, defaultEnabled: true
        ),
        FeatureDef(
            id: "system-restrictions", num: 46, title: "System Restrictions",
            subtitle: "Dev toggles — verifier, hidden APIs, SELinux (root)",
            keywords: [
                "restriction", "bypass", "verifier", "package verifier", "hidden api",
                "selinux", "setenforce", "permissive", "remount", "stay awake", "adb install",
            ],
            category: .deviceState, icon: "lock.open", kind: .view, defaultEnabled: true
        ),
        FeatureDef(
            id: "simulate", num: 48, title: "Simulate",
            subtitle: "Fake battery, appearance, locale, network & proxy",
            keywords: [
                "simulate", "device state", "override", "battery", "dark mode",
                "locale", "language", "font", "density", "animation", "network",
                "airplane", "proxy", "fake",
            ],
            category: .deviceState, icon: "slider.horizontal.3", kind: .view, defaultEnabled: true, needsDevice: false
        ),
        FeatureDef(
            id: "fake-battery", num: 18, title: "Fake Battery",
            subtitle: "Set a fake battery level and unplugged state",
            keywords: ["battery", "fake", "level", "unplugged", "charge"],
            category: .deviceState, icon: "battery.25percent", kind: .formAction, defaultEnabled: false,
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
            category: .deviceState, icon: "moon", kind: .toggleAction, defaultEnabled: false,
            isStateOverride: true, overrideKind: .darkMode,
            toggleOnLabel: "Dark", toggleOffLabel: "Light"
        ),
        FeatureDef(
            id: "layout-overrides", num: 20, title: "Font & Density",
            subtitle: "Override font scale and display density",
            keywords: ["font scale", "density", "dpi", "responsive", "layout", "text size"],
            category: .deviceState, icon: "ruler", kind: .formAction, defaultEnabled: false,
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
            category: .deviceState, icon: "speedometer", kind: .toggleAction, defaultEnabled: false,
            isStateOverride: true, overrideKind: .animation,
            toggleOnLabel: "Animations off (0×)", toggleOffLabel: "Animations on (1×)"
        ),
        FeatureDef(
            id: "locale", num: 22, title: "Change Locale",
            subtitle: "Switch device language for i18n testing",
            keywords: ["locale", "language", "i18n", "rtl", "translation"],
            category: .deviceState, icon: "character.bubble", kind: .formAction, defaultEnabled: false,
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
            category: .deviceState, icon: "antenna.radiowaves.left.and.right", kind: .formAction, defaultEnabled: false,
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
            category: .deviceState, icon: "point.3.connected.trianglepath.dotted", kind: .formAction, defaultEnabled: false,
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
            subtitle: "All installed & system apps with permissions",
            keywords: ["apps", "applications", "packages", "installed", "system", "permissions", "explore"],
            category: .appManagement, icon: "square.grid.3x3", kind: .view, defaultEnabled: true
        ),
        FeatureDef(
            id: "app-management", num: 25, title: "Manage App",
            subtitle: "Open, stop, clear, or uninstall an app",
            keywords: ["open", "close", "force stop", "clear data", "uninstall", "cache"],
            category: .appManagement, icon: "macwindow", kind: .view, defaultEnabled: false, needsBundle: true
        ),
        FeatureDef(
            id: "permissions", num: 26, title: "Permissions",
            subtitle: "Grant or revoke runtime permissions",
            keywords: ["permission", "grant", "revoke", "runtime", "checklist"],
            category: .appManagement, icon: "checkmark.shield", kind: .view, defaultEnabled: false, needsBundle: true
        ),
        FeatureDef(
            id: "app-info", num: 27, title: "App Info",
            subtitle: "Version, target SDK, size — and pull the APK",
            keywords: ["version", "version code", "sdk", "apk", "install date", "size"],
            category: .appManagement, icon: "shippingbox", kind: .view, defaultEnabled: false, needsBundle: true
        ),
        FeatureDef(
            id: "current-activity", num: 28, title: "Current Activity",
            subtitle: "Show the foreground Activity right now",
            keywords: ["activity", "foreground", "screen", "resumed", "dumpsys"],
            category: .appManagement, icon: "square.stack.3d.up", kind: .instantAction, defaultEnabled: false
        ),
        FeatureDef(
            id: "foreground-package", num: 37, title: "Copy Foreground Bundle ID",
            subtitle: "Get the package id of the app on screen now",
            keywords: ["package", "bundle id", "foreground", "current app", "which app"],
            category: .appManagement, icon: "scope", kind: .instantAction, defaultEnabled: false
        ),
        FeatureDef(
            id: "meminfo", num: 29, title: "Memory Usage",
            subtitle: "Live memory usage for an app",
            keywords: ["memory", "meminfo", "ram", "pss", "heap"],
            category: .appManagement, icon: "memorychip", kind: .view, defaultEnabled: false, needsBundle: true
        ),
        FeatureDef(
            id: "sandbox-browser", num: 30, title: "Sandbox Browser",
            subtitle: "Browse and pull app files (debug builds)",
            keywords: ["sandbox", "files", "run-as", "sqlite", "shared prefs", "mmkv"],
            category: .appManagement, icon: "folder", kind: .view, defaultEnabled: false, needsBundle: true
        ),
        FeatureDef(
            id: "monkey", num: 31, title: "Monkey Test",
            subtitle: "Fire random events to hunt for crashes",
            keywords: ["monkey", "stress", "random", "fuzz", "crash"],
            category: .appManagement, icon: "die.face.5", kind: .formAction, defaultEnabled: false, needsBundle: true,
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
            category: .logs, icon: "scroll", kind: .view, defaultEnabled: true
        ),
        FeatureDef(
            id: "crash-catcher", num: 33, title: "Crash Catcher",
            subtitle: "Filtered crashes + copy-last-crash for Slack/Jira",
            keywords: ["crash", "fatal", "exception", "androidruntime", "reactnativejs"],
            category: .logs, icon: "exclamationmark.triangle", kind: .view, defaultEnabled: false
        ),
        FeatureDef(
            id: "bug-report", num: 34, title: "Bug Report",
            subtitle: "Zip screenshot + logs + device info + version",
            keywords: ["bug report", "zip", "bundle", "diagnostics", "export"],
            category: .logs, icon: "doc.zipper", kind: .instantAction, defaultEnabled: false
        ),
        FeatureDef(
            id: "performance", num: 35, title: "Performance Monitor",
            subtitle: "Live CPU, RAM & FPS with recording and export",
            keywords: [
                "performance", "perf", "cpu", "core", "ram", "memory", "fps",
                "frame", "jank", "profiler", "monitor", "gfxinfo", "graph",
                "network", "speed", "bandwidth", "throughput", "upload", "download",
            ],
            category: .logs, icon: "chart.line.uptrend.xyaxis", kind: .view, defaultEnabled: true
        ),

        // ── Tool UX (system) ─────────────────────────────────────────────
        FeatureDef(
            id: "custom-commands", num: 36, title: "Custom Commands",
            subtitle: "Define your own adb actions with {bundleId}",
            keywords: ["custom", "command", "palette", "adb", "macro", "shortcut"],
            category: .toolUX, icon: "terminal", kind: .system, defaultEnabled: false, needsDevice: false
        ),
    ]

    public static let byID: [String: FeatureDef] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    /// The 12 features visible out of the box.
    public static let defaultEnabledIDs: [String] = all.filter(\.defaultEnabled).map(\.id)

    /// Always-available features (never hidden, not counted in "+N more").
    public static let systemFeatureIDs: [String] = all.filter { $0.kind == .system }.map(\.id)

    /// Hub screens and the individual features they gather. When a hub is first
    /// adopted, its members drop off the default sidebar (they stay searchable
    /// and hotkey-able). See `LayoutState.adoptNewDefaults`.
    public static let absorbedByHub: [String: [String]] = [
        "react-native": ["open-dev-menu", "reload-js", "deep-link", "process-death", "rn-dev-host"],
        "simulate": [
            "fake-battery", "dark-mode", "layout-overrides", "animation-scale",
            "locale", "network-toggles", "http-proxy",
        ],
        "connection": ["reverse-port", "disconnect", "private-dns", "wireless-adb"],
        // The Apps explorer already shows per-app permissions, info, and
        // management, so the standalone per-bundle screens fold into it.
        "apps": ["app-management", "permissions", "app-info"],
    ]
}
