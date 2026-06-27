import Foundation

public struct Avd: Sendable, Equatable, Identifiable {
    public let name: String
    /// adb serial (emulator-5554) when this AVD is currently running.
    public var runningSerial: String?

    public var id: String { name }
    public var displayName: String { name.replacingOccurrences(of: "_", with: " ") }
}

/// Android emulator management: list AVDs, see which are running, launch
/// (normal / cold boot / wipe data), and stop.
public struct EmulatorService: Sendable {
    let client: AdbClient
    let locator: ToolLocator
    let runner: any ProcessRunning

    public init(client: AdbClient, locator: ToolLocator, runner: any ProcessRunning = SystemProcessRunner()) {
        self.client = client
        self.locator = locator
        self.runner = runner
    }

    public func emulatorInstalled() async -> Bool {
        await locator.resolve(.emulator) != nil
    }

    /// Parse `emulator -list-avds` (skips INFO/warning noise lines).
    /// Splits on CharacterSet.newlines — "\r\n" is ONE Character in Swift,
    /// so splitting on "\n" silently fails on CRLF output.
    public static func parseAvdList(_ output: String) -> [String] {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("INFO") && !$0.contains("|") && !$0.contains(" ") }
    }

    /// All AVDs, with the running ones matched to their adb serial via
    /// `adb emu avd name`.
    public func listAvds(devices: [Device]) async -> [Avd] {
        guard let emulatorPath = await locator.resolve(.emulator) else { return [] }
        let output = await runner.run(
            executable: emulatorPath, arguments: ["-list-avds"],
            timeout: .seconds(15), maxOutputBytes: 1024 * 1024
        )
        var avds = Self.parseAvdList(output.stdoutText).map { Avd(name: $0) }

        for device in devices where device.serial.hasPrefix("emulator-") {
            guard let result = try? await client.run(on: device.serial, ["emu", "avd", "name"]) else { continue }
            // The emu console replies with \r\n — split on .newlines, since
            // "\r\n" is a single Character that "\n"-splitting misses.
            let name = result.stdout.components(separatedBy: .newlines).first
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let name, let index = avds.firstIndex(where: { $0.name == name }) {
                avds[index].runningSerial = device.serial
            }
        }
        return avds
    }

    public struct LaunchOptions: Sendable {
        public var coldBoot: Bool
        public var wipeData: Bool

        public init(coldBoot: Bool = false, wipeData: Bool = false) {
            self.coldBoot = coldBoot
            self.wipeData = wipeData
        }
    }

    /// Launch detached — the emulator outlives the app.
    public func launch(avd: String, options: LaunchOptions = LaunchOptions()) async -> FeatureResult {
        guard let emulatorPath = await locator.resolve(.emulator) else {
            return FeatureResult(ok: false, message: "Android emulator not found — install it via Android Studio's SDK Manager.")
        }
        var arguments = ["-avd", avd]
        if options.coldBoot {
            arguments.append("-no-snapshot-load")
        }
        if options.wipeData {
            arguments.append("-wipe-data")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: emulatorPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let sdkRoot = (emulatorPath as NSString).deletingLastPathComponent
        environment["ANDROID_HOME"] = environment["ANDROID_HOME"] ?? (sdkRoot as NSString).deletingLastPathComponent
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return FeatureResult(ok: true, message: "Launching \(avd)…")
        } catch {
            return FeatureResult(ok: false, message: "Couldn't launch the emulator: \(error.localizedDescription)")
        }
    }

    /// Graceful shutdown via the emulator console.
    public func stop(serial: String) async throws(AdbError) -> FeatureResult {
        let result = try await client.run(on: serial, ["emu", "kill"])
        return result.succeeded
            ? FeatureResult(ok: true, message: "Stopping emulator…")
            : FeatureResult(ok: false, message: friendlyAdbError(result, fallback: "Couldn't stop the emulator"))
    }

    /// pid of the process listening on the emulator's console port (the number
    /// in "emulator-5554"). That port is held by exactly that qemu process, so
    /// `lsof` maps the serial to the right pid even with several emulators up.
    /// Runs through the non-blocking runner so it can't park a cooperative
    /// thread (the reason this lives here, not in the view).
    public func consolePID(serial: String) async -> pid_t? {
        guard let port = serial.split(separator: "-").last.flatMap({ Int($0) }) else { return nil }
        let output = await runner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
            timeout: .seconds(5), maxOutputBytes: 64 * 1024
        )
        return Self.parseLsofPID(output.stdoutText)
    }

    /// First pid from `lsof -t` output (one pid per line; tolerates CRLF).
    static func parseLsofPID(_ output: String) -> pid_t? {
        output.split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .first
    }
}
