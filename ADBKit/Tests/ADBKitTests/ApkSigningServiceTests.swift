import Foundation
import Testing
@testable import ADBKit

@Suite struct ApkSigningServiceTests {
    // MARK: argument builders

    @Test func zipalignAlignsPagesAndOverwrites() {
        #expect(ApkSigningService.zipalignArguments(input: "/a/in.apk", output: "/a/out.apk")
            == ["-f", "-p", "4", "/a/in.apk", "/a/out.apk"])
    }

    @Test func signArgumentsReferencePasswordsByFileNotValue() {
        let args = ApkSigningService.signArguments(
            jar: "/sdk/apksigner.jar", keystore: "/keys/my.jks", storePassFile: "/tmp/sp",
            keyAlias: "release", keyPassFile: "/tmp/kp", target: "/a/out.apk")
        #expect(args == [
            "-jar", "/sdk/apksigner.jar", "sign", "--ks", "/keys/my.jks",
            "--ks-pass", "file:/tmp/sp", "--ks-key-alias", "release",
            "--key-pass", "file:/tmp/kp", "/a/out.apk",
        ])
    }

    @Test func signArgumentsOmitAliasWhenNotGiven() {
        let args = ApkSigningService.signArguments(
            jar: "j", keystore: "k", storePassFile: "sp", keyAlias: nil, keyPassFile: "kp", target: "t")
        #expect(!args.contains("--ks-key-alias"))
    }

    @Test func verifyArgumentsPrintCerts() {
        #expect(ApkSigningService.verifyArguments(jar: "j", target: "t")
            == ["-jar", "j", "verify", "-v", "--print-certs", "t"])
    }

    // MARK: behaviour

    @Test func signPassesPasswordByFileNeverOnTheCommandLine() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-f", "-p"], stdout: "")  // zipalign
        runner.script(argsPrefix: ["-jar"], stdout: "Verified using v2 scheme (APK Signature Scheme v2): true")
        let tools = try Self.makeBuildTools()
        let service = await Self.makeService(runner: runner, buildTools: tools.dir, java: tools.java)

        let secret = "sup3r-s3cret-pw"
        let result = try await service.sign(
            input: "/tmp/in.apk", output: "/tmp/out.apk",
            credentials: KeystoreCredentials(keystorePath: "/keys/r.jks", storePassword: secret, keyAlias: "r"))

        #expect(result.ok)
        #expect(result.signature?.schemes == ["v2"])
        // The secret must never appear as a process argument …
        #expect(!runner.invocations.contains { $0.arguments.contains(secret) })
        // … it's referenced through a file: argument instead.
        #expect(runner.invocations.contains { $0.arguments.contains { $0.hasPrefix("file:") } })
        // zipalign aligned input → output.
        #expect(runner.invocations.contains { $0.arguments == ["-f", "-p", "4", "/tmp/in.apk", "/tmp/out.apk"] })
    }

    @Test func signThrowsWhenToolsAreMissing() async {
        let runner = MockProcessRunner()
        let service = await Self.makeService(runner: runner, buildTools: nil, java: nil)
        await #expect(throws: ApkSigningService.SigningError.self) {
            try await service.sign(
                input: "/a", output: "/b",
                credentials: KeystoreCredentials(keystorePath: "k", storePassword: "p"))
        }
    }

    private static func makeService(runner: MockProcessRunner, buildTools: String?, java: String?) async -> ApkSigningService {
        let locator = ToolLocator(runner: runner, environment: [:])
        await locator.seedBuildToolsDir(buildTools)
        await locator.seedJava(java)
        let store = ManagedToolStore(
            rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("sign-store-\(UUID().uuidString)"))
        return ApkSigningService(toolchain: ApkToolchain(locator: locator, store: store), runner: runner)
    }

    private static func makeBuildTools() throws -> (dir: String, java: String) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("signbt-\(UUID().uuidString)")
        let buildTools = base.appendingPathComponent("build-tools/34.0.0")
        try fm.createDirectory(at: buildTools.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let exec: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        fm.createFile(atPath: buildTools.appendingPathComponent("zipalign").path, contents: Data("#!/bin/sh\n".utf8), attributes: exec)
        fm.createFile(atPath: buildTools.appendingPathComponent("lib/apksigner.jar").path, contents: Data())
        let java = base.appendingPathComponent("java")
        fm.createFile(atPath: java.path, contents: Data("#!/bin/sh\n".utf8), attributes: exec)
        return (buildTools.path, java.path)
    }
}
