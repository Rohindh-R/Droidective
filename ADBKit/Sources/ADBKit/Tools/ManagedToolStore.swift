import CryptoKit
import Foundation

/// Network seam for the tool store: fetch the releases JSON and download asset
/// files. Injected so the store's orchestration is tested without the network.
public protocol HTTPFetching: Sendable {
    func data(from url: URL) async throws -> Data
    /// Download `url` to `destination`, reporting download fraction (0…1) to
    /// `onProgress` as bytes arrive.
    func download(from url: URL, to destination: URL, onProgress: (@Sendable (Double) -> Void)?) async throws
}

extension HTTPFetching {
    /// Convenience for callers that don't need progress.
    public func download(from url: URL, to destination: URL) async throws {
        try await download(from: url, to: destination, onProgress: nil)
    }
}

/// `URLSession`-backed `HTTPFetching` with the GitHub API headers.
public struct URLSessionHTTP: HTTPFetching {
    public init() {}

    public func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Droidective", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        return data
    }

    public func download(from url: URL, to destination: URL, onProgress: (@Sendable (Double) -> Void)?) async throws {
        try await DownloadProgressDelegate(destination: destination, onProgress: onProgress).run(url: url)
    }

    static func check(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ManagedToolStore.StoreError.http(http.statusCode)
        }
    }
}

/// Bridges a delegate-based `URLSession` download to async/await so we get
/// byte-level progress. The session uses a serial delegate queue, so the mutable
/// state is touched on one thread only (hence `@unchecked Sendable`). The file is
/// moved inside `didFinishDownloadingTo` — its temp location is deleted as soon
/// as that returns.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?

    init(destination: URL, onProgress: (@Sendable (Double) -> Void)?) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(url: URL) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("Droidective", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let onProgress, totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try URLSessionHTTP.check(downloadTask.response)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }  // success is handled in didFinishDownloadingTo
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Downloads managed tools from their GitHub releases into Application Support,
/// verifies them, extracts them, and tracks the installed version so the app can
/// offer in-place upgrades. The signed `.app` is read-only, so tools live under
/// `rootDirectory` (Application Support), never inside the bundle.
///
/// Downloading and running third-party binaries is the riskiest part of the
/// feature, so every download is fetched over HTTPS and, when the release
/// publishes an asset digest, verified against it before use.
public actor ManagedToolStore {
    public enum StoreError: Error, LocalizedError, Equatable {
        case unsupported(ManagedTool)
        case noReleaseURL
        case noMatchingAsset(ManagedTool, arch: String)
        case digestMismatch
        case extractionFailed(String)
        case runnableNotFound(ManagedTool)
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let tool): "\(tool.rawValue) can't be managed yet."
            case .noReleaseURL: "Couldn't build the release URL."
            case .noMatchingAsset(let tool, let arch):
                "No \(tool.rawValue) download for \(arch.isEmpty ? "this platform" : arch)."
            case .digestMismatch: "The download failed its checksum — it may be corrupt or tampered with."
            case .extractionFailed(let reason): "Couldn't unpack the download: \(reason)"
            case .runnableNotFound(let tool): "Unpacked \(tool.rawValue) but couldn't find its program."
            case .http(let code): "Download failed (HTTP \(code))."
            }
        }
    }

    let rootDirectory: URL
    let http: any HTTPFetching
    let runner: any ProcessRunning
    private let fileManager = FileManager.default

    public init(
        rootDirectory: URL,
        http: any HTTPFetching = URLSessionHTTP(),
        runner: any ProcessRunning = SystemProcessRunner()
    ) {
        self.rootDirectory = rootDirectory
        self.http = http
        self.runner = runner
    }

    /// The Mac's architecture in Adoptium's asset naming — for the Temurin JRE.
    public static var macArch: String {
        #if arch(arm64)
        "aarch64"
        #else
        "x64"
        #endif
    }

    /// The installed version tag of `tool`, or nil when it isn't installed.
    public func installedVersion(_ tool: ManagedTool) -> String? {
        let marker = toolRoot(tool).appendingPathComponent("current.txt")
        guard let tag = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Path to the installed tool's runnable (jar or executable), or nil.
    public func resolve(_ tool: ManagedTool) -> String? {
        guard let tag = installedVersion(tool), let spec = ManagedToolSpec.catalog[tool] else { return nil }
        let versionDir = toolRoot(tool).appendingPathComponent(sanitize(tag), isDirectory: true)
        guard fileManager.fileExists(atPath: versionDir.path) else { return nil }
        return runnable(in: versionDir, spec: spec)
    }

    /// The on-disk directory holding `tool` (its versions + marker), or nil when
    /// it isn't installed.
    public func location(_ tool: ManagedTool) -> URL? {
        installedVersion(tool) == nil ? nil : toolRoot(tool)
    }

    /// Delete `tool` from disk entirely (all versions + the version marker).
    public func remove(_ tool: ManagedTool) throws {
        try fileManager.removeItem(at: toolRoot(tool))
    }

    /// Bytes occupied on disk under `url` (0 when absent). Pure file walk —
    /// `nonisolated` so a settings panel can size a tool off the actor.
    public nonisolated static func size(at url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// Newer version tag available for `tool`, or nil when it's current. A tool
    /// that isn't installed yet reports the latest tag as "available".
    public func upgradeAvailable(_ tool: ManagedTool, arch: String = "") async throws -> String? {
        let (_, release) = try await fetchRelease(tool)
        guard let installed = installedVersion(tool) else { return release.tagName }
        return ManagedToolReleases.isNewer(release.tagName, than: installed) ? release.tagName : nil
    }

    /// Download (or upgrade to) the latest release of `tool` and return the
    /// runnable's path. Idempotent: re-running with the current version reuses
    /// the existing install.
    @discardableResult
    public func install(
        _ tool: ManagedTool, arch: String = "", onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let (spec, release) = try await fetchRelease(tool)
        if installedVersion(tool) == release.tagName, let existing = resolve(tool) { return existing }
        guard let asset = ManagedToolReleases.selectAsset(release, spec: spec, arch: arch) else {
            throw StoreError.noMatchingAsset(tool, arch: arch)
        }
        guard let assetURL = URL(string: asset.downloadURL) else { throw StoreError.noReleaseURL }

        let stagingDir = toolRoot(tool).appendingPathComponent(".staging", isDirectory: true)
        try recreateDirectory(stagingDir)
        let downloaded = stagingDir.appendingPathComponent(asset.name)
        try await http.download(from: assetURL, to: downloaded, onProgress: onProgress)
        try verifyDigest(downloaded, expected: asset.digest)

        let versionDir = toolRoot(tool).appendingPathComponent(sanitize(release.tagName), isDirectory: true)
        try recreateDirectory(versionDir)
        try await place(asset: downloaded, spec: spec, into: versionDir)
        try? fileManager.removeItem(at: stagingDir)

        guard let runnablePath = runnable(in: versionDir, spec: spec) else {
            throw StoreError.runnableNotFound(tool)
        }
        try markCurrent(tool, tag: release.tagName)
        return runnablePath
    }

    // MARK: - Internals

    private func fetchRelease(_ tool: ManagedTool) async throws -> (ManagedToolSpec, GitHubRelease) {
        guard let spec = ManagedToolSpec.catalog[tool] else { throw StoreError.unsupported(tool) }
        guard let url = spec.latestReleaseURL else { throw StoreError.noReleaseURL }
        return (spec, try ManagedToolReleases.parse(try await http.data(from: url)))
    }

    /// Turn a downloaded asset into its installed form inside `dir`.
    private func place(asset: URL, spec: ManagedToolSpec, into dir: URL) async throws {
        switch spec.kind {
        case .jar:
            try fileManager.moveItem(at: asset, to: dir.appendingPathComponent(asset.lastPathComponent))
        case .zipArchive:
            try await extract("/usr/bin/unzip", ["-q", "-o", asset.path, "-d", dir.path])
        case .tarGz:
            try await extract("/usr/bin/tar", ["-xzf", asset.path, "-C", dir.path])
        case .xzBinary:
            // frida ships a bare .xz (macOS has no `xz` CLI) — decompress with the
            // system Compression framework into the runnable's fixed name.
            guard let name = spec.runnableName else { throw StoreError.runnableNotFound(spec.tool) }
            let compressed = try Data(contentsOf: asset)
            let decompressed = try (compressed as NSData).decompressed(using: .lzma) as Data
            let out = dir.appendingPathComponent(name)
            try decompressed.write(to: out, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path)
        }
    }

    private func extract(_ executable: String, _ args: [String]) async throws {
        let output = await runner.run(
            executable: executable, arguments: args, timeout: .seconds(120), maxOutputBytes: 1024 * 1024)
        guard output.exitCode == 0 else { throw StoreError.extractionFailed(output.stderrText) }
    }

    /// Verify a download against the release's `sha256:…` digest, when present.
    /// Older releases omit it; we proceed (HTTPS still applies) but can't checksum.
    private func verifyDigest(_ file: URL, expected: String?) throws {
        guard let expected, expected.hasPrefix("sha256:") else { return }
        let want = String(expected.dropFirst("sha256:".count)).lowercased()
        let digest = try SHA256.hash(data: Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard digest == want else {
            try? fileManager.removeItem(at: file)
            throw StoreError.digestMismatch
        }
    }

    /// The runnable inside an installed version dir: the jar for `.jar` tools,
    /// otherwise the spec's named executable found anywhere in the tree.
    private func runnable(in dir: URL, spec: ManagedToolSpec) -> String? {
        if spec.kind == .jar {
            return firstEntry(in: dir) { $0.pathExtension == "jar" }
        }
        // Match by name only: `unzip` doesn't preserve jadx's `bin/jadx` execute
        // bit, and we don't run that launcher anyway (we invoke `java -cp …`).
        // The runnables we do execute — the Temurin `java` (tar preserves +x) and
        // the `.xz` binaries (chmod'd on extraction) — are already executable.
        guard let name = spec.runnableName else { return nil }
        return firstEntry(in: dir) { $0.lastPathComponent == name }
    }

    private func firstEntry(in dir: URL, where matches: (URL) -> Bool) -> String? {
        guard let walker = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where matches(url) { return url.path }
        return nil
    }

    private func toolRoot(_ tool: ManagedTool) -> URL {
        rootDirectory.appendingPathComponent(tool.rawValue, isDirectory: true)
    }

    private func sanitize(_ tag: String) -> String {
        tag.replacingOccurrences(of: "/", with: "_")
    }

    private func recreateDirectory(_ url: URL) throws {
        try? fileManager.removeItem(at: url)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func markCurrent(_ tool: ManagedTool, tag: String) throws {
        try fileManager.createDirectory(at: toolRoot(tool), withIntermediateDirectories: true)
        try tag.write(to: toolRoot(tool).appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
    }
}
