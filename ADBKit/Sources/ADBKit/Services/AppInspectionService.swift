import Foundation

public struct PermissionEntry: Sendable, Equatable, Identifiable {
    public let name: String
    public var granted: Bool

    public var id: String { name }
    /// Short trailing component, e.g. "CAMERA".
    public var shortName: String { name.split(separator: ".").last.map(String.init) ?? name }
}

public struct AppInfo: Sendable, Equatable {
    public var installed: Bool
    public var versionName: String
    public var versionCode: String
    public var targetSdk: String
    public var minSdk: String
    public var firstInstall: String
    public var lastUpdate: String
    public var apkPath: String?
    public var apkSizeBytes: Int?

    public static let notInstalled = AppInfo(
        installed: false, versionName: "—", versionCode: "—", targetSdk: "—",
        minSdk: "—", firstInstall: "—", lastUpdate: "—", apkPath: nil, apkSizeBytes: nil
    )
}

public struct FsEntry: Sendable, Equatable, Identifiable {
    public let name: String
    public let isDir: Bool
    public let size: Int
    public let perms: String

    public var id: String { name }
}

public struct MemInfo: Sendable, Equatable {
    public var running: Bool
    public var totalPssKb: Int?
    public var summary: [(key: String, value: String)]

    public static func == (lhs: MemInfo, rhs: MemInfo) -> Bool {
        lhs.running == rhs.running && lhs.totalPssKb == rhs.totalPssKb
            && lhs.summary.map(\.key) == rhs.summary.map(\.key)
            && lhs.summary.map(\.value) == rhs.summary.map(\.value)
    }
}

/// Deep app inspection: permissions, app info + APK pull, foreground
/// activity, live memory, and run-as sandbox browsing.
public struct AppInspectionService: Sendable {
    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    // MARK: - Permissions

    public static func parsePermissions(_ dump: String) -> [PermissionEntry] {
        var permissions: [PermissionEntry] = []
        var inRuntime = false
        for line in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.range(of: "runtime permissions:", options: .caseInsensitive) != nil {
                inRuntime = true
                continue
            }
            guard inRuntime else { continue }
            if let match = line.firstMatch(of: /^\s+([\w.]+):\s+granted=(true|false)/) {
                permissions.append(PermissionEntry(name: String(match.1), granted: match.2 == "true"))
            } else if !permissions.isEmpty,
                      line.trimmingCharacters(in: .whitespaces).isEmpty
                        || line.range(of: #"^\s*\S+ (permissions|Packages):"#, options: [.regularExpression, .caseInsensitive]) != nil {
                break
            }
        }
        return permissions
    }

    public func listPermissions(serial: String, packageId: String) async throws(AdbError) -> [PermissionEntry] {
        let dump = try await client.run(on: serial, ["shell", "dumpsys", "package", packageId])
        return Self.parsePermissions(dump.stdout)
    }

    public func setPermission(
        serial: String, packageId: String, permission: String, grant: Bool
    ) async throws(AdbError) -> FeatureResult {
        let result = try await client.run(on: serial, [
            "shell", "pm", grant ? "grant" : "revoke", packageId, permission,
        ])
        let short = permission.split(separator: ".").last.map(String.init) ?? permission
        if result.succeeded {
            return FeatureResult(ok: true, message: "\(grant ? "Granted" : "Revoked") \(short)")
        }
        let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeatureResult(ok: false, message: reason.isEmpty ? "Only runtime permissions can be changed." : reason)
    }

    // MARK: - App info

    public static func parseAppInfo(_ dump: String, packageId: String) -> AppInfo {
        // Exact package-block match — a bare contains() would treat "com.foo"
        // as installed when only "com.foobar" is.
        guard dump.contains("Package [\(packageId)]") else { return .notInstalled }
        func first(_ pattern: String) -> String {
            guard let range = dump.range(of: pattern, options: .regularExpression) else { return "—" }
            let match = String(dump[range])
            return match.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "—"
        }
        return AppInfo(
            installed: true,
            versionName: first(#"versionName=\S+"#),
            versionCode: first(#"versionCode=\d+"#),
            targetSdk: first(#"targetSdk=\d+"#),
            minSdk: first(#"minSdk=\d+"#),
            firstInstall: first(#"firstInstallTime=[^\n]+"#),
            lastUpdate: first(#"lastUpdateTime=[^\n]+"#),
            apkPath: nil,
            apkSizeBytes: nil
        )
    }

    public func getAppInfo(serial: String, packageId: String) async throws(AdbError) -> AppInfo {
        let dump = try await client.run(on: serial, ["shell", "dumpsys", "package", packageId])
        var info = Self.parseAppInfo(dump.stdout, packageId: packageId)
        guard info.installed else { return info }

        if let apkPath = try await firstApkPath(serial: serial, packageId: packageId) {
            info.apkPath = apkPath
            let stat = try await client.run(on: serial, ["shell", "stat", "-c", "%s", apkPath])
            info.apkSizeBytes = Int(stat.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return info
    }

    func firstApkPath(serial: String, packageId: String) async throws(AdbError) -> String? {
        let output = try await client.run(on: serial, ["shell", "pm", "path", packageId])
        return output.stdout.split(separator: "\n")
            .map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    public func pullApk(serial: String, packageId: String, to destination: URL? = nil) async throws -> URL {
        guard let apkPath = try await firstApkPath(serial: serial, packageId: packageId) else {
            throw PullError.apkNotFound
        }
        let dest: URL
        if let destination {
            dest = destination
        } else {
            let dir = try ScreenCaptureService.ensureCaptureDir()
            dest = dir.appendingPathComponent("\(packageId)_\(ScreenCaptureService.stamp()).apk")
        }
        let result = try await client.run(on: serial, ["pull", apkPath, dest.path], timeout: .seconds(120))
        guard result.succeeded else {
            throw PullError.failed(friendlyAdbError(result, fallback: "Failed to pull APK"))
        }
        return dest
    }

    public enum PullError: Error, LocalizedError {
        case apkNotFound
        case notDebuggable
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .apkNotFound: return "APK path not found — is the app installed?"
            case .notDebuggable: return "App not debuggable — the sandbox needs a debug build."
            case .failed(let reason): return reason
            }
        }
    }

    // MARK: - Foreground activity

    public static func parseResumedActivity(_ dump: String) -> String? {
        let pattern = /(?:mResumedActivity|topResumedActivity|ResumedActivity):?[^\n]*?\bActivityRecord\{[^}]*?\s([\w.]+\/[\w.$]+)/
        return dump.firstMatch(of: pattern).map { String($0.1) }
    }

    public func getCurrentActivity(serial: String) async throws(AdbError) -> String? {
        let activities = try await client.run(on: serial, ["shell", "dumpsys", "activity", "activities"])
        if let resumed = Self.parseResumedActivity(activities.stdout) {
            return resumed
        }
        let windows = try await client.run(on: serial, ["shell", "dumpsys", "window", "windows"])
        if let match = windows.stdout.firstMatch(of: /mCurrentFocus=Window\{[^}]*?\s([\w.]+\/[\w.$]+)/) {
            return String(match.1)
        }
        return nil
    }

    public func getForegroundPackage(serial: String) async throws(AdbError) -> String? {
        guard let activity = try await getCurrentActivity(serial: serial) else { return nil }
        let package = activity.split(separator: "/").first.map(String.init)
        return package?.isEmpty == true ? nil : package
    }

    // MARK: - Memory

    public static func parseMemInfo(_ output: String) -> MemInfo {
        if output.range(of: "No process found", options: .caseInsensitive) != nil {
            return MemInfo(running: false, totalPssKb: nil, summary: [])
        }
        let total = output.firstMatch(of: /TOTAL(?: PSS)?:?\s+(\d+)/).flatMap { Int($0.1) }
        var summary: [(key: String, value: String)] = []
        for key in ["Native Heap", "Dalvik Heap", "Graphics", "Code", "Stack"] {
            if let range = output.range(of: "\(key)[:\\s]+(\\d+)", options: .regularExpression) {
                let digits = String(output[range]).filter(\.isNumber)
                summary.append((key, digits))
            }
        }
        if let total {
            summary.append(("TOTAL", String(total)))
        }
        return MemInfo(running: true, totalPssKb: total, summary: summary)
    }

    public func getMemInfo(serial: String, packageId: String) async throws(AdbError) -> MemInfo {
        let output = try await client.run(on: serial, ["shell", "dumpsys", "meminfo", packageId])
        return Self.parseMemInfo(output.stdout)
    }

    // MARK: - run-as sandbox

    static func isNotDebuggable(_ text: String) -> Bool {
        text.range(
            of: "not debuggable|not an application|unknown package|run-as: .*not",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public static func parseLsOutput(_ output: String) -> [FsEntry] {
        var entries: [FsEntry] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("total ") { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 8 else { continue }
            let name = parts[7...].joined(separator: " ")
            if name == "." || name == ".." { continue }
            entries.append(FsEntry(
                name: name,
                isDir: parts[0].hasPrefix("d"),
                size: Int(parts[4]) ?? 0,
                perms: parts[0]
            ))
        }
        return entries.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    public func sandboxList(
        serial: String, packageId: String, dir: String
    ) async throws(AdbError) -> (entries: [FsEntry], debuggable: Bool) {
        let result = try await client.run(on: serial, ["shell", "run-as", packageId, "ls", "-la", shellQuote(dir)])
        if Self.isNotDebuggable(result.stderr) {
            return ([], false)
        }
        return (Self.parseLsOutput(result.stdout), true)
    }

    public func sandboxPull(serial: String, packageId: String, filePath: String, to destination: URL? = nil) async throws -> URL {
        // `exec-out` escapes each argument itself (unlike `adb shell`, which runs the
        // joined command through a device shell), so the path goes raw — a shellQuote'd
        // path would reach `cat` with the literal quotes and fail to resolve.
        let output = try await client.runBinary(
            on: serial, ["exec-out", "run-as", packageId, "cat", filePath], timeout: .seconds(120)
        )
        if Self.isNotDebuggable(output.stderrText) {
            throw PullError.notDebuggable
        }
        guard output.exitCode == 0 else {
            throw PullError.failed(output.stderrText.isEmpty ? "Failed to pull file" : output.stderrText)
        }
        let dest: URL
        if let destination {
            dest = destination
        } else {
            let dir = try ScreenCaptureService.ensureCaptureDir()
            let filename = (filePath as NSString).lastPathComponent
            dest = dir.appendingPathComponent(filename.isEmpty ? "file" : filename)
        }
        try output.stdout.write(to: dest)
        return dest
    }
}
