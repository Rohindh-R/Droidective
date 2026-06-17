import Foundation

/// Pulls an app's launcher icon off the device *without* downloading the whole
/// APK. An APK is a zip, so `unzip -p <apk> <entry>` streams only the chosen
/// icon's bytes. We list entries with `unzip -l`, pick the sharpest raster
/// `ic_launcher`, and stream just that. Results are cached on disk so the list
/// only pays the cost once per app.
public struct AppIconService: Sendable {
    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    // Density buckets, richest first — we want the sharpest raster icon.
    static let densityOrder: [(token: String, rank: Int)] = [
        ("xxxhdpi", 6), ("xxhdpi", 5), ("xhdpi", 4),
        ("hdpi", 3), ("mdpi", 2), ("ldpi", 1), ("nodpi", 0), ("anydpi", 0),
    ]

    /// Parse the `Name` column out of `unzip -l` output, skipping the header,
    /// separator, and total lines. Each entry line is
    /// "  <length>  <date>  <time>   <name>" — the header/total lines don't
    /// start with a numeric length and are dropped.
    public static func parseUnzipListing(_ output: String) -> [String] {
        var names: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, Int(fields[0]) != nil else { continue }
            let name = fields[3...].joined(separator: " ")
            if !name.isEmpty {
                names.append(name)
            }
        }
        return names
    }

    /// Choose the best launcher-icon entry from an APK's file listing. Prefers
    /// a raster `ic_launcher` at the highest density, then round / foreground /
    /// any mipmap raster. Returns nil when only vector (.xml) icons exist — the
    /// caller falls back to a monogram.
    public static func pickIconEntry(_ entries: [String]) -> String? {
        var best: (entry: String, score: Int)?
        for entry in entries {
            let lower = entry.lowercased()
            guard lower.hasSuffix(".png") || lower.hasSuffix(".webp") else { continue }
            let name = (lower as NSString).lastPathComponent
            let baseScore: Int
            if name == "ic_launcher.png" || name == "ic_launcher.webp" {
                baseScore = 1000
            } else if name.contains("ic_launcher") && name.contains("round") {
                baseScore = 800
            } else if name.contains("ic_launcher") && name.contains("foreground") {
                baseScore = 700
            } else if name.contains("ic_launcher") {
                baseScore = 750
            } else if lower.contains("/mipmap") && name.contains("icon") {
                baseScore = 300
            } else if lower.contains("/mipmap") {
                baseScore = 200
            } else {
                continue
            }
            let score = baseScore + density(lower)
            if best == nil || score > best!.score {
                best = (entry, score)
            }
        }
        return best?.entry
    }

    static func density(_ path: String) -> Int {
        for (token, rank) in densityOrder where path.contains(token) {
            return rank
        }
        return 0
    }

    /// The launcher-icon bytes (PNG/WebP) for one package, or nil if the app
    /// ships no raster icon (or the device lacks `unzip`). Cached on disk.
    public func iconData(serial: String, packageId: String) async -> Data? {
        if let cached = Self.cachedData(packageId: packageId) {
            return cached.isEmpty ? nil : cached
        }
        guard let apk = await apkPath(serial: serial, packageId: packageId) else { return nil }

        guard let listing = try? await client.run(
            on: serial, ["exec-out", "unzip", "-l", apk], timeout: .seconds(20)
        ), listing.succeeded else {
            return nil
        }
        guard let entry = Self.pickIconEntry(Self.parseUnzipListing(listing.stdout)) else {
            Self.cache(packageId: packageId, data: Data()) // sentinel: no raster icon
            return nil
        }

        guard let output = try? await client.runBinary(
            on: serial, ["exec-out", "unzip", "-p", apk, entry], timeout: .seconds(20)
        ), output.exitCode == 0, !output.stdout.isEmpty else {
            return nil
        }
        Self.cache(packageId: packageId, data: output.stdout)
        return output.stdout
    }

    private func apkPath(serial: String, packageId: String) async -> String? {
        guard let result = try? await client.run(on: serial, ["shell", "pm", "path", packageId]) else { return nil }
        let paths = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "package:", with: "") }
            .filter { !$0.isEmpty }
        return paths.first { $0.hasSuffix("base.apk") } ?? paths.first
    }

    // MARK: - Disk cache (~/Library/Application Support/Droidective/IconCache)

    static func cacheDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("Droidective/IconCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(packageId: String) -> URL? {
        cacheDirectory()?.appendingPathComponent("\(packageId).img")
    }

    static func cachedData(packageId: String) -> Data? {
        guard let url = cacheURL(packageId: packageId) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func cache(packageId: String, data: Data) {
        guard let url = cacheURL(packageId: packageId) else { return }
        try? data.write(to: url)
    }
}
