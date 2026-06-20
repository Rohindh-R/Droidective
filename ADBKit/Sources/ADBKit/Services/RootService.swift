import Foundation

/// One signal contributing to the root verdict, shown as a row in the UI.
public struct RootSignal: Sendable, Equatable, Identifiable {
    public let name: String
    public let detail: String
    /// Whether this signal points toward the device being rooted.
    public let indicatesRoot: Bool

    public var id: String { name }

    public init(name: String, detail: String, indicatesRoot: Bool) {
        self.name = name
        self.detail = detail
        self.indicatesRoot = indicatesRoot
    }
}

/// The outcome of a root probe across several independent signals.
public struct RootStatus: Sendable, Equatable {
    /// `su -c id` actually returned uid 0 — the only definitive proof, and
    /// what root-gated features (Wi-Fi passwords, SELinux, remount) require.
    public let hasRootShell: Bool
    /// Best guess combining the shell test with weaker signals (su binary,
    /// Magisk, test-keys build). True when any strong signal fires.
    public let likelyRooted: Bool
    public let summary: String
    public let signals: [RootSignal]

    public init(hasRootShell: Bool, likelyRooted: Bool, summary: String, signals: [RootSignal]) {
        self.hasRootShell = hasRootShell
        self.likelyRooted = likelyRooted
        self.summary = summary
        self.signals = signals
    }
}

/// Detects root and runs commands as root. Detection is best-effort: each
/// probe that fails (command missing, su denied) just contributes a negative
/// signal rather than throwing.
public struct RootService: Sendable {
    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    /// Common on-device locations for the `su` binary.
    static let suPaths = [
        "/system/bin/su", "/system/xbin/su", "/sbin/su",
        "/su/bin/su", "/magisk/.core/bin/su", "/data/local/tmp/su",
    ]

    /// Files that exist only on a Magisk-rooted device.
    static let magiskPaths = ["/sbin/.magisk", "/data/adb/magisk", "/data/adb/modules"]

    /// Run a command as root: `adb shell su -c '<command>'`. The command is
    /// quoted so the device shell passes it to `su` as a single argument
    /// instead of splitting it on spaces.
    public func suRun(serial: String, _ command: String) async throws(AdbError) -> AdbResult {
        try await client.run(on: serial, ["shell", "su", "-c", shellQuote(command)])
    }

    public func detect(serial: String) async -> RootStatus {
        let idOutput = (try? await suRun(serial: serial, "id"))?.stdout ?? ""
        let whichSu = (try? await client.run(on: serial, ["shell", "which", "su"]))?.stdout ?? ""
        let suList = (try? await client.run(on: serial, ["shell", "ls", "-d"] + Self.suPaths))?.stdout ?? ""
        let magiskList = (try? await client.run(on: serial, ["shell", "ls", "-d"] + Self.magiskPaths))?.stdout ?? ""
        let props = (try? await DeviceProps.all(client: client, serial: serial)) ?? [:]
        let enforce = (try? await client.run(on: serial, ["shell", "getenforce"]))?.stdout ?? ""

        return Self.evaluate(
            idOutput: idOutput, whichSu: whichSu, suList: suList,
            magiskList: magiskList, props: props, getenforce: enforce
        )
    }

    /// Pure verdict from raw command output — unit-tested without a device.
    static func evaluate(
        idOutput: String,
        whichSu: String,
        suList: String,
        magiskList: String,
        props: [String: String],
        getenforce: String
    ) -> RootStatus {
        let hasRootShell = idOutput.contains("uid=0")
        let suBinary = !whichSu.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || anyPathExists(suList)
        let magisk = anyPathExists(magiskList)
        let tags = props["ro.build.tags"] ?? ""
        let testKeys = tags.contains("test-keys")
        let debuggable = props["ro.debuggable"] == "1"
        let insecure = props["ro.secure"] == "0"
        let permissive = getenforce.lowercased().contains("permissive")

        let signals: [RootSignal] = [
            RootSignal(
                name: "Root shell (su)",
                detail: hasRootShell ? "su -c id → uid=0" : "su unavailable or denied",
                indicatesRoot: hasRootShell
            ),
            RootSignal(
                name: "su binary",
                detail: suBinary ? "found on PATH or a known location" : "not found",
                indicatesRoot: suBinary
            ),
            RootSignal(
                name: "Magisk",
                detail: magisk ? "Magisk files present" : "not detected",
                indicatesRoot: magisk
            ),
            RootSignal(
                name: "Build tags",
                detail: tags.isEmpty ? "unknown" : tags,
                indicatesRoot: testKeys
            ),
            RootSignal(
                name: "ro.debuggable",
                detail: debuggable ? "1 (debuggable build)" : "0 (production build)",
                indicatesRoot: debuggable
            ),
            RootSignal(
                name: "ro.secure",
                detail: insecure ? "0 (insecure adbd)" : "1 (secure)",
                indicatesRoot: insecure
            ),
            RootSignal(
                name: "SELinux",
                detail: getenforce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "unknown" : getenforce.trimmingCharacters(in: .whitespacesAndNewlines),
                indicatesRoot: permissive
            ),
        ]

        let likelyRooted = hasRootShell || suBinary || magisk
        let method: String
        if magisk {
            method = "Magisk"
        } else if hasRootShell {
            method = "root shell"
        } else if suBinary {
            method = "su binary"
        } else {
            method = ""
        }
        let summary: String
        if hasRootShell {
            summary = "Rooted · \(method)"
        } else if likelyRooted {
            summary = "Likely rooted · \(method) (su not granted over adb)"
        } else {
            summary = "Not rooted"
        }
        return RootStatus(hasRootShell: hasRootShell, likelyRooted: likelyRooted, summary: summary, signals: signals)
    }

    /// True if an `ls -d <paths…>` listing contains at least one real path
    /// (missing paths report to stderr, so stdout holds only existing ones).
    static func anyPathExists(_ lsStdout: String) -> Bool {
        lsStdout.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("/")
                && !trimmed.lowercased().contains("no such")
                && !trimmed.lowercased().contains("not found")
        }
    }
}
