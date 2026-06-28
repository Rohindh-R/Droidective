import Foundation

/// A node in a decompiled-output tree, for the browser view. `children` is nil
/// for files; directories list their (sorted) contents.
public struct FileNode: Sendable, Equatable, Identifiable {
    public var name: String
    public var path: String
    public var children: [FileNode]?

    public var id: String { path }
    public var isDirectory: Bool { children != nil }

    public init(name: String, path: String, children: [FileNode]? = nil) {
        self.name = name
        self.path = path
        self.children = children
    }
}

/// Decompiles an APK with managed tools: jadx for readable Java, apktool for
/// smali + decoded resources; and rebuilds an apktool tree back into an APK.
///
/// Everything runs as `java …` against the toolchain-resolved JDK and the
/// downloaded tool, into a contained output directory. The APK and output paths
/// are argument-vector elements (no shell). Decompiled output is untrusted input
/// — the browser only reads and displays it.
public struct DecompileService: Sendable {
    public enum Mode: String, Sendable, CaseIterable {
        case jadx     // → Java sources
        case apktool  // → smali + decoded resources/manifest
    }

    public enum DecompileError: Error, LocalizedError, Equatable {
        case toolMissing(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .toolMissing(let what): "\(what) isn't installed yet."
            case .failed(let reason): reason.isEmpty ? "Decompilation failed." : reason
            }
        }
    }

    let toolchain: ApkToolchain
    let runner: any ProcessRunning

    public init(toolchain: ApkToolchain, runner: any ProcessRunning = SystemProcessRunner()) {
        self.toolchain = toolchain
        self.runner = runner
    }

    /// Decompile `apkPath` into a fresh `<name>-<mode>` dir under `outputRoot`.
    public func decompile(apkPath: String, mode: Mode, into outputRoot: URL) async throws -> URL {
        guard let java = await toolchain.java() else { throw DecompileError.toolMissing("Java") }
        let name = URL(fileURLWithPath: apkPath).deletingPathExtension().lastPathComponent
        let outDir = outputRoot.appendingPathComponent("\(name)-\(mode.rawValue)", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let arguments: [String]
        switch mode {
        case .jadx:
            guard let jadx = await toolchain.jadx() else { throw DecompileError.toolMissing("jadx") }
            arguments = Self.jadxArguments(libDir: Self.jadxLibDir(forRunnable: jadx), output: outDir.path, apk: apkPath)
        case .apktool:
            guard let apktool = await toolchain.apktool() else { throw DecompileError.toolMissing("apktool") }
            arguments = Self.apktoolDecodeArguments(jar: apktool, output: outDir.path, apk: apkPath)
        }
        let result = await runner.run(executable: java, arguments: arguments, timeout: .seconds(600), maxOutputBytes: 8 << 20)
        // jadx and apktool exit non-zero on per-item errors (a handful of classes
        // that won't decompile) while still writing all the usable output, so
        // treat a non-empty output directory as success; only fail when nothing
        // landed.
        let produced = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path).isEmpty) == false
        guard produced else {
            let message = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
            throw DecompileError.failed(message.isEmpty ? "Decompilation produced no output." : message)
        }
        return outDir
    }

    /// Rebuild an apktool source tree back into an APK (then sign it to install).
    public func rebuild(sourceDir: String, to outputApk: String) async throws {
        guard let java = await toolchain.java() else { throw DecompileError.toolMissing("Java") }
        guard let apktool = await toolchain.apktool() else { throw DecompileError.toolMissing("apktool") }
        let result = await runner.run(
            executable: java, arguments: Self.apktoolBuildArguments(jar: apktool, sourceDir: sourceDir, output: outputApk),
            timeout: .seconds(600), maxOutputBytes: 8 << 20)
        guard result.exitCode == 0 else {
            throw DecompileError.failed(result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
        }
    }

    // MARK: - Pure argument builders

    /// jadx ships a `bin/jadx` launcher beside a `lib/` of jars; we run the CLI
    /// main directly off that classpath so we don't depend on the launcher
    /// finding a JDK on the app's minimal PATH.
    static func jadxArguments(libDir: String, output: String, apk: String) -> [String] {
        ["-cp", "\(libDir)/*", "jadx.cli.JadxCLI", "-d", output, apk]
    }

    static func apktoolDecodeArguments(jar: String, output: String, apk: String) -> [String] {
        ["-jar", jar, "d", "-f", "-o", output, apk]
    }

    static func apktoolBuildArguments(jar: String, sourceDir: String, output: String) -> [String] {
        ["-jar", jar, "b", sourceDir, "-o", output]
    }

    /// `…/bin/jadx` → `…/lib` (its sibling), regardless of any version wrapper dir.
    static func jadxLibDir(forRunnable runnable: String) -> String {
        URL(fileURLWithPath: runnable)
            .deletingLastPathComponent()      // …/bin
            .deletingLastPathComponent()      // …/<jadx root>
            .appendingPathComponent("lib").path
    }

    // MARK: - Output tree

    /// Walk a decompiled directory into a `FileNode` tree (directories first,
    /// then files, each alphabetical). Bounded by `maxDepth` so a pathological
    /// tree can't recurse without limit.
    public static func tree(at url: URL, maxDepth: Int = 16) -> FileNode {
        let name = url.lastPathComponent
        guard maxDepth > 0,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else {
            return FileNode(name: name, path: url.path)
        }
        let children = entries
            .map { tree(at: $0, maxDepth: maxDepth - 1) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        return FileNode(name: name, path: url.path, children: children)
    }
}
