import Foundation

/// Shared-storage file operations for the File Explorer: list, mkdir,
/// copy/move, delete, and pull. All paths are quoted for the device shell.
public struct FileExplorerService: Sendable {
    public static let defaultRoot = "/sdcard"

    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    public func list(serial: String, dir: String) async throws(AdbError) -> [FsEntry] {
        // Trailing slash so symlinked dirs (/sdcard → /storage/self/primary)
        // list their contents, not the link itself.
        let result = try await client.run(on: serial, ["shell", "ls", "-la", shellQuote(dir + "/")])
        return AppInspectionService.parseLsOutput(result.stdout)
    }

    public func makeDirectory(serial: String, path: String) async throws(AdbError) -> FeatureResult {
        let result = try await client.run(on: serial, ["shell", "mkdir", "-p", shellQuote(path)])
        return verdict(result, success: "Folder created", fallback: "Couldn't create the folder")
    }

    public func delete(serial: String, path: String) async throws(AdbError) -> FeatureResult {
        let result = try await client.run(on: serial, ["shell", "rm", "-rf", shellQuote(path)], timeout: .seconds(120))
        return verdict(result, success: "Deleted", fallback: "Couldn't delete")
    }

    /// Device-side copy (paste after Copy).
    public func copy(serial: String, from source: String, toDir dest: String) async throws(AdbError) -> FeatureResult {
        let result = try await client.run(
            on: serial, ["shell", "cp", "-r", shellQuote(source), shellQuote(dest)], timeout: .seconds(300)
        )
        return verdict(result, success: "Copied", fallback: "Copy failed")
    }

    /// Device-side move (paste after Cut).
    public func move(serial: String, from source: String, toDir dest: String) async throws(AdbError) -> FeatureResult {
        let result = try await client.run(
            on: serial, ["shell", "mv", shellQuote(source), shellQuote(dest)], timeout: .seconds(300)
        )
        return verdict(result, success: "Moved", fallback: "Move failed")
    }

    /// Pull a file or directory. `destination: nil` lands in
    /// ~/Downloads/Droidective under the source's name.
    public func pull(serial: String, path: String, to destination: URL? = nil) async throws -> URL {
        let name = (path as NSString).lastPathComponent
        let dest: URL
        if let destination {
            dest = destination
        } else {
            let dir = try ScreenCaptureService.ensureCaptureDir()
            dest = dir.appendingPathComponent(name.isEmpty ? "file" : name)
        }
        let result = try await client.run(on: serial, ["pull", path, dest.path], timeout: .seconds(600))
        guard result.succeeded else {
            throw AppInspectionService.PullError.failed(friendlyAdbError(result, fallback: "Failed to pull \(name)"))
        }
        return dest
    }

    public struct FileInfo: Sendable, Equatable {
        public var type: String
        public var sizeBytes: Int?
        public var owner: String
        public var permissions: String
        /// Last content modification.
        public var modified: String
        /// Last metadata change — Android/Linux doesn't record creation time.
        public var changed: String
    }

    /// Detailed metadata via `stat`. Creation time isn't tracked by the
    /// filesystem; `changed` is the closest available.
    public func info(serial: String, path: String) async throws(AdbError) -> FileInfo? {
        let format = "%F|%s|%U|%A|%y|%z"
        let result = try await client.run(
            on: serial, ["shell", "stat", "-c", shellQuote(format), shellQuote(path)]
        )
        guard result.succeeded else { return nil }
        return Self.parseStat(result.stdout)
    }

    static func parseStat(_ output: String) -> FileInfo? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 6 else { return nil }
        func trimDate(_ value: String) -> String {
            // "2026-06-12 18:03:11.123456789 +0530" → drop sub-second noise.
            value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        }
        return FileInfo(
            type: fields[0].capitalized,
            sizeBytes: Int(fields[1]),
            owner: fields[2],
            permissions: fields[3],
            modified: trimDate(fields[4]),
            changed: trimDate(fields[5])
        )
    }

    /// Push a Mac file/folder to a device directory. Paths go straight to
    /// adb's sync protocol — no device shell, so no quoting.
    public func push(serial: String, localPath: String, toDir remoteDir: String) async throws(AdbError) -> FeatureResult {
        let name = (localPath as NSString).lastPathComponent
        let result = try await client.run(
            on: serial, ["push", localPath, remoteDir + "/" + name], timeout: .seconds(600)
        )
        return result.succeeded
            ? FeatureResult(ok: true, message: "Pushed \(name)")
            : FeatureResult(ok: false, message: friendlyAdbError(result, fallback: "Failed to push \(name)"))
    }

    private func verdict(_ result: AdbResult, success: String, fallback: String) -> FeatureResult {
        if result.succeeded && result.stderr.isEmpty {
            return FeatureResult(ok: true, message: success)
        }
        return FeatureResult(ok: false, message: friendlyAdbError(result, fallback: fallback))
    }
}
