import Foundation

/// Lifecycle state of a package for the current user.
public struct AppLifecycle: Sendable, Equatable {
    public let disabled: Bool
    /// Uninstalled for the current user (still on the system image, restorable).
    public let removed: Bool

    public var label: String {
        if removed { return "Removed" }
        return disabled ? "Disabled" : "Enabled"
    }

    public init(disabled: Bool, removed: Bool) {
        self.disabled = disabled
        self.removed = removed
    }
}

/// How an uninstall-for-user attempt resolved, read back from the package's
/// post-attempt lifecycle.
public enum UninstallOutcome: Sendable, Equatable {
    /// Gone from the device entirely — a user app, removed for good.
    case removed
    /// Still on the system image but uninstalled for this user (restorable).
    case removedForUser
    /// Still installed — the package manager refused (a protected package).
    case stillInstalled
}

/// App lifecycle control behind the Apps view: disable, uninstall-for-user, or
/// restore any package. All actions are reversible (`pm enable` /
/// `cmd package install-existing`) and per-user — they never touch the system
/// image, so no root is required.
public struct SystemAppsService: Sendable {
    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    /// Lifecycle (disabled / removed-for-user) of every package on the device,
    /// keyed by package id.
    public func states(serial: String) async -> [String: AppLifecycle] {
        let installed = await packages(serial: serial, flags: [])
        let disabled = await packages(serial: serial, flags: ["-d"])
        let known = await packages(serial: serial, flags: ["-u"])
        return Self.lifecycleMap(installed: installed, disabled: disabled, known: known)
    }

    private func packages(serial: String, flags: [String]) async -> Set<String> {
        let output = (try? await client.run(
            on: serial, ["shell", "pm", "list", "packages"] + flags, timeout: .seconds(30)
        ))?.stdout ?? ""
        return Self.parsePackageList(output)
    }

    public func setDisabled(serial: String, packageId: String, _ disabled: Bool) async throws(AdbError) -> AdbResult {
        if disabled {
            return try await client.run(on: serial, ["shell", "pm", "disable-user", "--user", "0", packageId])
        }
        return try await client.run(on: serial, ["shell", "pm", "enable", packageId])
    }

    public func setRemoved(serial: String, packageId: String, _ removed: Bool) async throws(AdbError) -> AdbResult {
        if removed {
            return try await client.run(on: serial, ["shell", "pm", "uninstall", "--user", "0", packageId])
        }
        return try await client.run(on: serial, ["shell", "cmd", "package", "install-existing", packageId])
    }

    // MARK: - Parsing

    static func parsePackageList(_ output: String) -> Set<String> {
        var packages: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("package:") else { continue }
            // `-u`/`-U` can append " uid:NNNN"; keep only the package name.
            let rest = trimmed.dropFirst("package:".count)
            let name = rest.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if !name.isEmpty { packages.insert(name) }
        }
        return packages
    }

    static func lifecycleMap(
        installed: Set<String>, disabled: Set<String>, known: Set<String>
    ) -> [String: AppLifecycle] {
        var map: [String: AppLifecycle] = [:]
        for package in known.union(installed) {
            map[package] = AppLifecycle(disabled: disabled.contains(package), removed: !installed.contains(package))
        }
        return map
    }

    /// Classify an uninstall-for-user attempt from the package's post-attempt
    /// lifecycle. A `nil` entry means the package is no longer known to the
    /// device — a user app removed for good, which is success, not a failure.
    public static func uninstallOutcome(for entry: AppLifecycle?) -> UninstallOutcome {
        guard let entry else { return .removed }
        return entry.removed ? .removedForUser : .stillInstalled
    }
}
