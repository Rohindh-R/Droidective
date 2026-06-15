import Foundation

public struct AppListing: Sendable, Equatable, Identifiable {
    public let packageId: String
    public let versionName: String?
    public let isSystem: Bool

    public var id: String { packageId }
    /// Display name derived from the package id ("weather" → "Weather").
    public var displayName: String {
        packageId.split(separator: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? packageId
    }

    public func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        return packageId.localizedCaseInsensitiveContains(query)
            || displayName.localizedCaseInsensitiveContains(query)
            || (versionName?.localizedCaseInsensitiveContains(query) ?? false)
    }
}

/// Lists every installed app (user + system) with versions in two adb calls:
/// one `dumpsys package packages` parse for versions, one `pm list -3` for
/// the user-installed set — no per-app round-trips.
public struct AppsExplorerService: Sendable {
    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    /// Parse `dumpsys package packages`: "Package [id]" blocks each followed
    /// (eventually) by a versionName line.
    public static func parseVersions(_ dump: String) -> [String: String] {
        var versions: [String: String] = [:]
        var currentPackage: String?
        for line in dump.split(whereSeparator: \.isNewline) {
            if let match = line.firstMatch(of: /Package \[([\w.]+)\]/) {
                currentPackage = String(match.1)
            } else if let package = currentPackage,
                      versions[package] == nil,
                      let match = line.firstMatch(of: /versionName=(\S+)/) {
                versions[package] = String(match.1)
            }
        }
        return versions
    }

    public func listAll(serial: String) async throws(AdbError) -> [AppListing] {
        let dump = try await client.run(
            on: serial, ["shell", "dumpsys", "package", "packages"],
            timeout: .seconds(60), maxOutputBytes: 50 * 1024 * 1024
        )
        let versions = Self.parseVersions(dump.stdout)

        let userList = try await client.run(on: serial, ["shell", "pm", "list", "packages", "-3"])
        let userPackages = Set(
            userList.stdout.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "package:", with: "") }
                .filter { !$0.isEmpty }
        )

        let allList = try await client.run(on: serial, ["shell", "pm", "list", "packages"])
        let allPackages = allList.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "package:", with: "") }
            .filter { !$0.isEmpty }

        return allPackages
            .map { package in
                AppListing(
                    packageId: package,
                    versionName: versions[package],
                    isSystem: !userPackages.contains(package)
                )
            }
            .sorted {
                if $0.isSystem != $1.isSystem { return !$0.isSystem } // user apps first
                return $0.packageId < $1.packageId
            }
    }
}
