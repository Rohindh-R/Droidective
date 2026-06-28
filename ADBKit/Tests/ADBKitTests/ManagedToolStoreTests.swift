import CryptoKit
import Foundation
import Testing
@testable import ADBKit

@Suite struct ManagedToolStoreTests {
    /// Canned network: every `data(from:)` returns the same release JSON, every
    /// download writes the same asset bytes. Extraction uses the real runner.
    final class MockHTTP: HTTPFetching, @unchecked Sendable {
        let releaseJSON: Data
        let assetBytes: Data
        init(releaseJSON: Data, assetBytes: Data) {
            self.releaseJSON = releaseJSON
            self.assetBytes = assetBytes
        }
        func data(from url: URL) async throws -> Data { releaseJSON }
        func download(from url: URL, to destination: URL) async throws {
            try assetBytes.write(to: destination, options: .atomic)
        }
    }

    private func releaseJSON(tag: String, assetName: String, digest: String? = nil) -> Data {
        let digestField = digest.map { #","digest":"\#($0)""# } ?? ""
        let json = #"{"tag_name":"\#(tag)","assets":[{"name":"\#(assetName)","browser_download_url":"https://example/\#(assetName)","size":7\#(digestField)}]}"#
        return Data(json.utf8)
    }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("toolstore-\(UUID().uuidString)")
    }

    @Test func installsApktoolJarAndResolvesIt() async throws {
        let bytes = Data("FAKE-JAR".utf8)
        let http = MockHTTP(releaseJSON: releaseJSON(tag: "v2.11.0", assetName: "apktool_2.11.0.jar"), assetBytes: bytes)
        let store = ManagedToolStore(rootDirectory: tempRoot(), http: http)

        let path = try await store.install(.apktool)

        #expect(path.hasSuffix("apktool_2.11.0.jar"))
        #expect(await store.installedVersion(.apktool) == "v2.11.0")
        #expect(await store.resolve(.apktool) == path)
        #expect(FileManager.default.contents(atPath: path) == bytes)
    }

    @Test func verifiesAssetDigestWhenPresent() async throws {
        let bytes = Data("signed-payload".utf8)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let http = MockHTTP(
            releaseJSON: releaseJSON(tag: "v1.3.0", assetName: "uber-apk-signer-1.3.0.jar", digest: "sha256:\(sha)"),
            assetBytes: bytes)
        let store = ManagedToolStore(rootDirectory: tempRoot(), http: http)

        let path = try await store.install(.uberApkSigner)
        #expect(path.hasSuffix(".jar"))
    }

    @Test func rejectsAssetWithMismatchedDigestAndInstallsNothing() async throws {
        let http = MockHTTP(
            releaseJSON: releaseJSON(tag: "v1", assetName: "apktool_x.jar", digest: "sha256:deadbeef"),
            assetBytes: Data("not-the-signed-bytes".utf8))
        let store = ManagedToolStore(rootDirectory: tempRoot(), http: http)

        await #expect(throws: ManagedToolStore.StoreError.digestMismatch) {
            try await store.install(.apktool)
        }
        #expect(await store.installedVersion(.apktool) == nil)
        #expect(await store.resolve(.apktool) == nil)
    }

    @Test func installsTarGzAndFindsTheNestedRunnable() async throws {
        // Real .tar.gz fixture, extracted by the real runner — exercises the
        // tar path and the recursive runnable search (Temurin's java is nested).
        let tgz = try Self.makeTarGz(runnableRelPath: "Contents/Home/bin/java")
        let asset = "OpenJDK21U-jre_aarch64_mac_hotspot_21.0.4_7.tar.gz"
        let http = MockHTTP(releaseJSON: releaseJSON(tag: "jdk-21.0.4+7", assetName: asset), assetBytes: tgz)
        let store = ManagedToolStore(rootDirectory: tempRoot(), http: http)

        let path = try await store.install(.temurinJre, arch: "aarch64")

        #expect(path.hasSuffix("/bin/java"))
        #expect(FileManager.default.isExecutableFile(atPath: path))
        #expect(await store.resolve(.temurinJre) == path)
    }

    @Test func detectsAnUpgradeAndAppliesIt() async throws {
        let root = tempRoot()
        let v210 = MockHTTP(releaseJSON: releaseJSON(tag: "v2.10.0", assetName: "apktool_2.10.0.jar"), assetBytes: Data("a".utf8))
        let store = ManagedToolStore(rootDirectory: root, http: v210)
        _ = try await store.install(.apktool)
        #expect(try await store.upgradeAvailable(.apktool) == nil)   // same tag → current

        let v211 = MockHTTP(releaseJSON: releaseJSON(tag: "v2.11.0", assetName: "apktool_2.11.0.jar"), assetBytes: Data("b".utf8))
        let upgraded = ManagedToolStore(rootDirectory: root, http: v211)
        #expect(try await upgraded.upgradeAvailable(.apktool) == "v2.11.0")
        _ = try await upgraded.install(.apktool)
        #expect(await upgraded.installedVersion(.apktool) == "v2.11.0")
    }

    /// A real `.tar.gz` containing a single executable at `runnableRelPath`
    /// under a top-level `jdk-21/` dir, mirroring Temurin's layout.
    private static func makeTarGz(runnableRelPath: String) throws -> Data {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tgz-src-\(UUID().uuidString)")
        let runnable = work.appendingPathComponent("jdk-21").appendingPathComponent(runnableRelPath)
        try fm.createDirectory(at: runnable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho java\n".write(to: runnable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnable.path)
        let out = work.appendingPathComponent("out.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", out.path, "-C", work.path, "jdk-21"]
        try tar.run()
        tar.waitUntilExit()
        return try Data(contentsOf: out)
    }
}
