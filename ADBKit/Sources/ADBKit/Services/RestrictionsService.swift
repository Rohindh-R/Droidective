import Foundation

/// Current state of the system-restriction toggles. Booleans describe the
/// *current* device state, not the action.
public struct RestrictionsState: Sendable, Equatable {
    /// ADB installs are verified before completing (default on).
    public var adbInstallVerification: Bool
    /// The package verifier is enabled (default on).
    public var packageVerifier: Bool
    /// Screen stays awake while charging.
    public var stayAwake: Bool
    /// Hidden-API restrictions are enforced (default on).
    public var hiddenApiEnforced: Bool
    /// SELinux mode — true Enforcing, false Permissive, nil unknown (root only).
    public var selinuxEnforcing: Bool?

    public init(
        adbInstallVerification: Bool, packageVerifier: Bool, stayAwake: Bool,
        hiddenApiEnforced: Bool, selinuxEnforcing: Bool?
    ) {
        self.adbInstallVerification = adbInstallVerification
        self.packageVerifier = packageVerifier
        self.stayAwake = stayAwake
        self.hiddenApiEnforced = hiddenApiEnforced
        self.selinuxEnforcing = selinuxEnforcing
    }
}

/// Toggle dev-time system restrictions. The install/API toggles are global
/// settings (no root); SELinux and remounting the system partition need root.
public struct RestrictionsService: Sendable {
    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    public func current(serial: String) async -> RestrictionsState {
        let adbInstall = await getGlobal(serial, "verifier_verify_adb_installs")
        let packageVerifier = await getGlobal(serial, "package_verifier_enable")
        let stayAwake = await getGlobal(serial, "stay_on_while_plugged_in")
        let hiddenApi = await getGlobal(serial, "hidden_api_policy")
        let enforce = (try? await client.run(on: serial, ["shell", "getenforce"]))?.stdout ?? ""
        return Self.parseState(
            adbInstall: adbInstall, packageVerifier: packageVerifier,
            stayAwake: stayAwake, hiddenApi: hiddenApi, getenforce: enforce
        )
    }

    private func getGlobal(_ serial: String, _ key: String) async -> String {
        (try? await client.run(on: serial, ["shell", "settings", "get", "global", key]))?.stdout ?? ""
    }

    public func setAdbInstallVerification(serial: String, _ on: Bool) async throws(AdbError) -> AdbResult {
        try await putGlobal(serial, "verifier_verify_adb_installs", on ? "1" : "0")
    }

    public func setPackageVerifier(serial: String, _ on: Bool) async throws(AdbError) -> AdbResult {
        try await putGlobal(serial, "package_verifier_enable", on ? "1" : "0")
    }

    public func setStayAwake(serial: String, _ on: Bool) async throws(AdbError) -> AdbResult {
        try await putGlobal(serial, "stay_on_while_plugged_in", on ? "7" : "0")
    }

    /// `hidden_api_policy = 1` disables enforcement (apps may call hidden APIs);
    /// deleting the key restores the platform default (enforced).
    public func setHiddenApiEnforced(serial: String, _ enforced: Bool) async throws(AdbError) -> AdbResult {
        if enforced {
            return try await client.run(on: serial, ["shell", "settings", "delete", "global", "hidden_api_policy"])
        }
        return try await putGlobal(serial, "hidden_api_policy", "1")
    }

    public func setSelinuxEnforcing(serial: String, _ enforcing: Bool) async throws(AdbError) -> AdbResult {
        try await client.run(on: serial, ["shell", "su", "-c", shellQuote("setenforce \(enforcing ? 1 : 0)")])
    }

    public func remountSystemReadWrite(serial: String) async throws(AdbError) -> AdbResult {
        try await client.run(on: serial, ["shell", "su", "-c", shellQuote("mount -o rw,remount /")])
    }

    private func putGlobal(_ serial: String, _ key: String, _ value: String) async throws(AdbError) -> AdbResult {
        try await client.run(on: serial, ["shell", "settings", "put", "global", key, value])
    }

    static func parseState(
        adbInstall: String, packageVerifier: String, stayAwake: String,
        hiddenApi: String, getenforce: String
    ) -> RestrictionsState {
        func intValue(_ raw: String, default fallback: Int) -> Int {
            Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
        }
        let enforce = getenforce.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selinux: Bool?
        if enforce.contains("enforcing") {
            selinux = true
        } else if enforce.contains("permissive") {
            selinux = false
        } else {
            selinux = nil
        }
        return RestrictionsState(
            adbInstallVerification: intValue(adbInstall, default: 1) != 0,
            packageVerifier: intValue(packageVerifier, default: 1) != 0,
            stayAwake: intValue(stayAwake, default: 0) != 0,
            hiddenApiEnforced: intValue(hiddenApi, default: 0) == 0,
            selinuxEnforcing: selinux
        )
    }
}
