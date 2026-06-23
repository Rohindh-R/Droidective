import Foundation

/// Outcome of running one feature against one target.
public struct FeatureResult: Sendable, Equatable {
    public var ok: Bool
    public var message: String
    /// When set, the UI offers a one-click copy (e.g. device IP).
    public var copyText: String?
    /// When set, the UI offers Reveal in Finder (e.g. screenshot path).
    public var revealPath: String?
    /// True when the failure is the missing ADBKeyboard IME — the UI offers
    /// a one-click install.
    public var needsAdbKeyboard: Bool

    public init(
        ok: Bool,
        message: String,
        copyText: String? = nil,
        revealPath: String? = nil,
        needsAdbKeyboard: Bool = false
    ) {
        self.ok = ok
        self.message = message
        self.copyText = copyText
        self.revealPath = revealPath
        self.needsAdbKeyboard = needsAdbKeyboard
    }
}

/// Backend command-spec mirror of the feature registry. Each runner executes
/// one feature against a device (or globally) and returns a friendly result.
/// Keyed by the same feature ids the registry uses — ids are the contract.
public struct FeatureEngine: Sendable {
    public let client: AdbClient
    public let locator: ToolLocator
    public let monitor: DeviceMonitor
    public let appControl: AppControlService
    public let inspection: AppInspectionService
    public let toolDetection: ToolDetectionService
    public let overrides: OverridesService
    public let connection: ConnectionService
    public let crash: CrashExtractor
    public let bugReport: BugReportService
    public let customCommands: CustomCommandService
    public let adbKeyboard: AdbKeyboardInstaller
    public let fileExplorer: FileExplorerService
    public let appsExplorer: AppsExplorerService
    public let appIcons: AppIconService
    public let emulators: EmulatorService
    public let performance: PerformanceService
    public let networkSpeed: NetworkSpeedService
    public let root: RootService
    public let wifi: WifiService
    public let systemApps: SystemAppsService
    public let dns: DnsService
    public let restrictions: RestrictionsService
    let textInput: TextInputService
    let screenCapture: ScreenCaptureService

    public init(client: AdbClient, locator: ToolLocator, monitor: DeviceMonitor, overridesStore: JSONStore<OverridesMap>) {
        self.client = client
        self.locator = locator
        self.monitor = monitor
        self.appControl = AppControlService(client: client)
        self.inspection = AppInspectionService(client: client)
        self.toolDetection = ToolDetectionService(locator: locator)
        self.overrides = OverridesService(client: client, store: overridesStore)
        self.connection = ConnectionService(client: client, monitor: monitor)
        self.crash = CrashExtractor(client: client)
        self.bugReport = BugReportService(client: client)
        self.customCommands = CustomCommandService(client: client)
        self.adbKeyboard = AdbKeyboardInstaller(client: client)
        self.fileExplorer = FileExplorerService(client: client)
        self.appsExplorer = AppsExplorerService(client: client)
        self.appIcons = AppIconService(client: client)
        self.emulators = EmulatorService(client: client, locator: locator)
        self.performance = PerformanceService(client: client)
        self.networkSpeed = NetworkSpeedService(client: client)
        self.root = RootService(client: client)
        self.wifi = WifiService(client: client)
        self.systemApps = SystemAppsService(client: client)
        self.dns = DnsService(client: client)
        self.restrictions = RestrictionsService(client: client)
        self.textInput = TextInputService(client: client)
        self.screenCapture = ScreenCaptureService(client: client)
    }

    /// Feature ids with a working runner. The UI shows a "coming soon"
    /// placeholder for registry entries not yet listed here.
    public static let implementedIDs: Set<String> = [
        "send-text", "get-ip", "reverse-port",
        "open-dev-menu", "reload-js", "screenshot",
        "scrcpy", "deep-link", "app-management", "logcat",
        "demo-mode", "dark-mode", "animation-scale", "fake-battery",
        "layout-overrides", "locale", "network-toggles", "http-proxy",
        "permissions", "app-info", "current-activity", "foreground-package",
        "meminfo", "sandbox-browser", "monkey", "device-info",
        "screen-record", "crash-catcher", "bug-report", "wireless-adb",
        "rn-dev-host", "process-death", "custom-commands",
        "file-explorer", "apps", "emulators", "performance", "network-speed",
        "root-status", "wifi", "private-dns", "system-restrictions",
    ]

    /// Screenshot with an explicit destination (UI asks the user first).
    public func captureScreenshot(serial: String, to destination: URL) async throws -> URL {
        try await screenCapture.captureScreenshot(serial: serial, to: destination)
    }

    /// Screenshot returned as raw PNG bytes — for the editor, which saves on demand.
    public func captureScreenshotData(serial: String) async throws -> Data {
        try await screenCapture.captureScreenshotData(serial: serial)
    }

    /// Run a feature against one serial (or globally for global-scope ids).
    public func run(featureID: String, serial: String, params: [String: FeatureValue]) async -> FeatureResult {
        do {
            return try await dispatch(featureID: featureID, serial: serial, params: params)
        } catch {
            return FeatureResult(ok: false, message: error.localizedDescription)
        }
    }

    private func dispatch(
        featureID: String,
        serial: String,
        params: [String: FeatureValue]
    ) async throws -> FeatureResult {
        switch featureID {
        case "send-text":
            let text = params["text"]?.stringValue ?? ""
            return try await textInput.send(serial: serial, text: text)

        case "get-ip":
            return try await getIP(serial: serial)

        case "reverse-port":
            return try await reversePort(serial: serial, params: params)

        case "open-dev-menu":
            let result = try await client.run(on: serial, ["shell", "input", "keyevent", "82"])
            return fromResult(result, success: "Opened the dev menu", fallback: "Failed to open the dev menu")

        case "reload-js":
            let result = try await client.run(on: serial, ["shell", "input", "keyevent", "46", "46"])
            return fromResult(result, success: "Reloaded JS", fallback: "Failed to reload JS")

        case "screenshot":
            let file = try await screenCapture.captureScreenshot(serial: serial)
            return FeatureResult(ok: true, message: "Screenshot saved", revealPath: file.path)

        case "scrcpy":
            return await launchScrcpy(serial: serial)

        case "demo-mode":
            let on = params["on"]?.boolValue == true
            try await overrides.applyDemo(serial: serial, on: on)
            return FeatureResult(ok: true, message: on ? "Demo mode on (clean status bar)" : "Demo mode off")

        case "dark-mode":
            let on = params["on"]?.boolValue == true
            try await overrides.applyDarkMode(serial: serial, on: on)
            return FeatureResult(ok: true, message: on ? "Switched to dark mode" : "Switched to light mode")

        case "animation-scale":
            let off = params["on"]?.boolValue == true
            try await overrides.applyAnimation(serial: serial, off: off)
            return FeatureResult(ok: true, message: off ? "Animations off (0×)" : "Animations on (1×)")

        case "fake-battery":
            guard let raw = params["level"]?.numberValue, (0...100).contains(Int(raw.rounded())) else {
                return FeatureResult(ok: false, message: "Battery level must be 0–100.")
            }
            let unplugged = params["unplugged"]?.boolValue ?? true
            let value = try await overrides.applyBattery(serial: serial, level: Int(raw.rounded()), unplugged: unplugged)
            return FeatureResult(ok: true, message: "Battery faked: \(value)")

        case "layout-overrides":
            guard let fontScale = params["fontScale"]?.numberValue else {
                return FeatureResult(ok: false, message: "Invalid font scale.")
            }
            let density = params["density"]?.numberValue.flatMap { $0 > 0 ? Int($0) : nil }
            let value = try await overrides.applyLayout(serial: serial, fontScale: fontScale, density: density)
            return FeatureResult(ok: true, message: "Applied \(value)")

        case "locale":
            guard let locale = params["locale"]?.stringValue, !locale.isEmpty else {
                return FeatureResult(ok: false, message: "Pick a locale.")
            }
            _ = try await overrides.applyLocale(serial: serial, locale: locale)
            return FeatureResult(
                ok: true,
                message: "Locale set to \(locale) — may need an app restart (full change can require root)."
            )

        case "http-proxy":
            let proxy = (params["proxy"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            if proxy.isEmpty {
                try await overrides.reset(serial: serial, kind: .proxy)
                return FeatureResult(ok: true, message: "Proxy cleared")
            }
            guard proxy.contains(":"), proxy.split(separator: ":").last.map({ Int($0) != nil }) == true else {
                return FeatureResult(ok: false, message: "Use host:port, e.g. 10.0.0.5:8888.")
            }
            _ = try await overrides.applyProxy(serial: serial, proxy: proxy)
            return FeatureResult(ok: true, message: "Proxy set to \(proxy)")

        case "bug-report":
            let packageId = params["packageId"]?.stringValue
            let zipPath = try await bugReport.create(serial: serial, packageId: packageId)
            return FeatureResult(ok: true, message: "Bug report saved", revealPath: zipPath.path)

        case "process-death":
            guard let package = params["packageId"]?.stringValue, !package.isEmpty else {
                return FeatureResult(ok: false, message: "Pick a saved bundle first.")
            }
            _ = try await client.run(on: serial, ["shell", "input", "keyevent", "3"]) // HOME → background
            let killResult = try await client.run(on: serial, ["shell", "am", "kill", package])
            return killResult.succeeded
                ? FeatureResult(ok: true, message: "Killed \(package) in the background — reopen to test state restoration.")
                : FeatureResult(ok: false, message: friendlyAdbError(killResult, fallback: "Failed to kill the app"))

        case "rn-dev-host":
            let host = (params["host"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else {
                return FeatureResult(ok: false, message: "Enter a host:port (e.g. 192.168.1.10:8081).")
            }
            let port = host.contains(":") ? String(host.split(separator: ":").last ?? "8081") : "8081"
            _ = try await client.run(on: serial, ["reverse", "tcp:\(port)", "tcp:\(port)"])
            return FeatureResult(
                ok: true,
                message: "Reverse-tunneled :\(port). For a remote Metro IP, also set it in the RN dev menu → Settings → Debug server host."
            )

        case "current-activity":
            guard let activity = try await inspection.getCurrentActivity(serial: serial) else {
                return FeatureResult(ok: false, message: "Couldn't determine the foreground activity.")
            }
            return FeatureResult(ok: true, message: "Foreground: \(activity)", copyText: activity)

        case "foreground-package":
            guard let package = try await inspection.getForegroundPackage(serial: serial) else {
                return FeatureResult(ok: false, message: "Couldn't read the foreground app — is the screen on?")
            }
            return FeatureResult(ok: true, message: "Foreground app: \(package)", copyText: package)

        case "monkey":
            guard let package = params["packageId"]?.stringValue, !package.isEmpty else {
                return FeatureResult(ok: false, message: "Pick a saved bundle first.")
            }
            let count = max(1, Int((params["count"]?.numberValue ?? 500).rounded()))
            let result = try await client.run(
                on: serial,
                ["shell", "monkey", "-p", package, "-v", String(count)],
                timeout: .seconds(120)
            )
            return result.succeeded
                ? FeatureResult(ok: true, message: "Fired \(count) random events at \(package)")
                : FeatureResult(ok: false, message: friendlyAdbError(result, fallback: "Monkey run failed"))

        case "network-toggles":
            let wifi = params["wifi"]?.boolValue ?? true
            let data = params["data"]?.boolValue ?? true
            let airplane = params["airplane"]?.boolValue ?? false
            let wifiResult = try await client.run(on: serial, ["shell", "svc", "wifi", wifi ? "enable" : "disable"])
            let dataResult = try await client.run(on: serial, ["shell", "svc", "data", data ? "enable" : "disable"])
            let airplaneResult = try await client.run(on: serial, [
                "shell", "cmd", "connectivity", "airplane-mode", airplane ? "enable" : "disable",
            ])
            var failed: [String] = []
            if !wifiResult.succeeded { failed.append("Wi-Fi") }
            if !dataResult.succeeded { failed.append("data") }
            if !airplaneResult.succeeded { failed.append("airplane") }
            guard failed.isEmpty else {
                return FeatureResult(
                    ok: false,
                    message: "Couldn't set \(failed.joined(separator: ", ")) — the ROM may not allow it over adb."
                )
            }
            return FeatureResult(
                ok: true,
                message: "Wi-Fi \(wifi ? "on" : "off") · data \(data ? "on" : "off") · airplane \(airplane ? "on" : "off")"
            )

        default:
            return FeatureResult(ok: false, message: "\"\(featureID)\" isn't implemented yet.")
        }
    }

    func fromResult(_ result: AdbResult, success: String, fallback: String) -> FeatureResult {
        result.succeeded
            ? FeatureResult(ok: true, message: success)
            : FeatureResult(ok: false, message: friendlyAdbError(result, fallback: fallback))
    }

    static func parseIP(_ output: String) -> String? {
        if let match = output.firstMatch(of: /inet (\d{1,3}(?:\.\d{1,3}){3})/) {
            return String(match.1)
        }
        if let match = output.firstMatch(of: /src (\d{1,3}(?:\.\d{1,3}){3})/) {
            return String(match.1)
        }
        return nil
    }

    private func getIP(serial: String) async throws(AdbError) -> FeatureResult {
        let wlan = try await client.run(on: serial, ["shell", "ip", "-f", "inet", "addr", "show", "wlan0"])
        var ip = Self.parseIP(wlan.stdout)
        if ip == nil {
            let route = try await client.run(on: serial, ["shell", "ip", "route"])
            ip = Self.parseIP(route.stdout)
        }
        guard let ip else {
            return FeatureResult(ok: false, message: "Couldn't determine the device IP (is Wi-Fi on?).")
        }
        return FeatureResult(ok: true, message: "Device IP: \(ip)", copyText: ip)
    }

    private func reversePort(serial: String, params: [String: FeatureValue]) async throws(AdbError) -> FeatureResult {
        guard let raw = params["port"]?.numberValue,
              raw.truncatingRemainder(dividingBy: 1) == 0,
              (1...65535).contains(Int(raw))
        else {
            return FeatureResult(ok: false, message: "Enter a valid port (1–65535).")
        }
        let port = Int(raw)
        let result = try await client.run(on: serial, ["reverse", "tcp:\(port)", "tcp:\(port)"])
        return fromResult(result, success: "Reversed port \(port)", fallback: "Failed to reverse port")
    }

    /// Launch scrcpy detached: null stdio, no wait, never killed on app quit.
    ///
    /// scrcpy resolves `adb` itself via $ADB or PATH — a Finder-launched app
    /// has neither, so both must be injected or scrcpy dies instantly.
    public func launchScrcpy(
        serial: String,
        options: ScrcpyOptions = ScrcpyOptions(),
        recordingPath: String? = nil
    ) async -> FeatureResult {
        guard let scrcpyPath = await locator.resolve(.scrcpy) else {
            return FeatureResult(ok: false, message: "scrcpy isn't installed. Run `brew install scrcpy`, then try again.")
        }
        guard let adbPath = await locator.resolve(.adb) else {
            return FeatureResult(ok: false, message: "adb not found — scrcpy needs it to connect.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        process.arguments = ["-s", serial] + options.args(recordingPath: recordingPath)
        var environment = ProcessInfo.processInfo.environment
        environment["ADB"] = adbPath
        // A bundled scrcpy (Contents/Helpers/scrcpy) ships its server alongside
        // it under Contents/Resources; point scrcpy at it. A Homebrew scrcpy
        // finds its own server, so this is skipped when the file isn't present.
        let bundledServer = URL(fileURLWithPath: scrcpyPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/scrcpy-server")
        if FileManager.default.fileExists(atPath: bundledServer.path) {
            environment["SCRCPY_SERVER_PATH"] = bundledServer.path
        }
        let extraPaths = [
            (adbPath as NSString).deletingLastPathComponent,
            (scrcpyPath as NSString).deletingLastPathComponent,
        ]
        environment["PATH"] = (extraPaths + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return FeatureResult(ok: true, message: "Launched scrcpy")
        } catch {
            return FeatureResult(ok: false, message: "Couldn't launch scrcpy: \(error.localizedDescription)")
        }
    }

}
