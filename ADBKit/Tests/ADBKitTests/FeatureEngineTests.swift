import Foundation
import Testing
@testable import ADBKit

/// Asserts each implemented runner issues exactly the adb arguments the
/// reference implementation does — the regression net for ported features.
@Suite struct FeatureEngineTests {
    private func makeEngine(_ runner: MockProcessRunner) async -> FeatureEngine {
        let client = await makeTestClient(runner: runner)
        return FeatureEngine(
            client: client, locator: client.locator, monitor: DeviceMonitor(client: client),
            overridesStore: makeTempOverridesStore()
        )
    }

    @Test func devMenuSendsKeyevent82() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "open-dev-menu", serial: "S1", params: [:])
        #expect(result.ok)
        #expect(runner.invocations.last?.arguments == ["-s", "S1", "shell", "input", "keyevent", "82"])
    }

    @Test func reloadJsSendsDoubleKeyevent46() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "reload-js", serial: "S1", params: [:])
        #expect(result.ok)
        #expect(runner.invocations.last?.arguments == ["-s", "S1", "shell", "input", "keyevent", "46", "46"])
    }

    @Test func reversePortValidatesAndRuns() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let engine = await makeEngine(runner)

        let bad = await engine.run(featureID: "reverse-port", serial: "S1", params: ["port": .string("99999")])
        #expect(!bad.ok)
        #expect(bad.message == "Enter a valid port (1–65535).")
        #expect(runner.invocations.isEmpty)

        let good = await engine.run(featureID: "reverse-port", serial: "S1", params: ["port": .string("8081")])
        #expect(good.ok)
        #expect(good.message == "Reversed port 8081")
        #expect(runner.invocations.last?.arguments == ["-s", "S1", "reverse", "tcp:8081", "tcp:8081"])
    }

    @Test func disconnectAllOmitsTarget() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["disconnect"], stdout: "")
        runner.script(argsPrefix: ["devices"], stdout: "List of devices attached\n")
        let engine = await makeEngine(runner)

        let result = try await engine.connection.disconnect(target: nil)
        #expect(result.ok)
        #expect(result.message == "Disconnected all wireless devices")
        #expect(runner.invocations.contains { $0.arguments == ["disconnect"] })
    }

    @Test func disconnectWithTargetPassesIt() async throws {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["disconnect"], stdout: "")
        runner.script(argsPrefix: ["devices"], stdout: "List of devices attached\n")
        let engine = await makeEngine(runner)

        let result = try await engine.connection.disconnect(target: "192.168.1.42:5555")
        #expect(result.message == "Disconnected 192.168.1.42:5555")
        #expect(runner.invocations.contains { $0.arguments == ["disconnect", "192.168.1.42:5555"] })
    }

    @Test func getIpParsesWlanThenFallsBackToRoute() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "ip", "-f"], stdout: "wlan0: no address")
        runner.script(
            argsPrefix: ["-s", "S1", "shell", "ip", "route"],
            stdout: "default via 192.168.1.1 dev wlan0 src 10.1.2.3"
        )
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "get-ip", serial: "S1", params: [:])
        #expect(result.ok)
        #expect(result.copyText == "10.1.2.3")
    }

    @Test func sendTextAsciiUsesInputText() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "send-text", serial: "S1", params: ["text": .string("hi there")])
        #expect(result.ok)
        #expect(runner.invocations.last?.arguments == ["-s", "S1", "shell", "input", "text", "hi%sthere"])
    }

    @Test func sendTextUnicodeWithoutAdbKeyboardFails() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s", "S1", "shell", "ime", "list"], stdout: "com.google.android.inputmethod.latin/.IME")
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "send-text", serial: "S1", params: ["text": .string("héllo")])
        #expect(!result.ok)
        #expect(result.message.contains("ADBKeyboard"))
    }

    @Test func networkTogglesReportsSuccessWhenAllCommandsSucceed() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        let engine = await makeEngine(runner)

        let result = await engine.run(
            featureID: "network-toggles", serial: "S1",
            params: ["wifi": .bool(false), "data": .bool(true), "airplane": .bool(false)]
        )
        #expect(result.ok)
        #expect(result.message.contains("Wi-Fi off"))
    }

    @Test func networkTogglesReportsFailureInsteadOfFalseSuccess() async {
        let runner = MockProcessRunner()
        runner.script(argsPrefix: ["-s"], stdout: "")
        // `svc data disable` is rejected on this ROM.
        runner.script(argsPrefix: ["-s", "S1", "shell", "svc", "data"], stderr: "Permission denial", exitCode: 1)
        let engine = await makeEngine(runner)

        let result = await engine.run(
            featureID: "network-toggles", serial: "S1",
            params: ["wifi": .bool(true), "data": .bool(false), "airplane": .bool(false)]
        )
        #expect(!result.ok)
        #expect(result.message.contains("data"))
    }

    @Test func unimplementedFeatureReportsPlaceholder() async {
        let runner = MockProcessRunner()
        let engine = await makeEngine(runner)

        let result = await engine.run(featureID: "logcat", serial: "S1", params: [:])
        #expect(!result.ok)
        #expect(result.message.contains("isn't implemented yet"))
    }
}

@Suite struct FeatureRegistryTests {
    @Test func hasAll48Features() {
        #expect(FeatureRegistry.all.count == 48)
        #expect(FeatureRegistry.byID.count == 48)
    }

    @Test func everyCatalogFeatureIsEnabledByDefault() {
        // Every feature is on out of the box — the default set is exactly the
        // catalog (non-absorbed) features. Hub members are folded into their
        // hub and never appear as standalone default rows.
        #expect(Set(FeatureRegistry.defaultEnabledIDs) == Set(FeatureRegistry.catalogFeatureIDs))
        #expect(Set(FeatureRegistry.defaultEnabledIDs).isDisjoint(with: FeatureRegistry.absorbedFeatureIDs))
    }

    @Test func hubMembersAreHiddenFromCatalogButStayInRegistry() {
        let absorbed = FeatureRegistry.absorbedFeatureIDs
        #expect(!absorbed.isEmpty)
        // Hub members remain in the registry, so they stay hotkey-able and
        // reachable through their hub …
        for id in absorbed {
            #expect(FeatureRegistry.byID[id] != nil, "absorbed id \(id) missing from registry")
            #expect(FeatureRegistry.byID[id]?.isAbsorbedByHub == true)
        }
        // … but never appear in the catalog or the default sidebar.
        #expect(absorbed.isDisjoint(with: Set(FeatureRegistry.catalogFeatureIDs)))
        #expect(absorbed.isDisjoint(with: Set(FeatureRegistry.defaultEnabledIDs)))
        // The hub screens that gather them stay catalog-visible.
        for hub in FeatureRegistry.absorbedByHub.keys {
            #expect(FeatureRegistry.catalogFeatureIDs.contains(hub), "hub \(hub) should stay in the catalog")
            #expect(FeatureRegistry.byID[hub]?.isAbsorbedByHub == false)
        }
    }

    @Test func catalogIsTheRegistryMinusHubMembers() {
        #expect(
            FeatureRegistry.catalogFeatureIDs.count
                == FeatureRegistry.all.count - FeatureRegistry.absorbedFeatureIDs.count
        )
    }

    @Test func everyFeatureHasAHowToNote() {
        for feature in FeatureRegistry.all {
            #expect(FeatureRegistry.howTo(for: feature.id) != nil, "missing howTo for \(feature.id)")
        }
    }

    @Test func everyFeatureHasACommandReference() {
        for feature in FeatureRegistry.all {
            #expect(!FeatureRegistry.commands(for: feature.id).isEmpty, "missing commands for \(feature.id)")
        }
    }

    @Test func commandReferenceLeadsWithTheTool() {
        for feature in FeatureRegistry.all {
            for command in FeatureRegistry.commands(for: feature.id) {
                let leadsWithTool = ["adb ", "scrcpy ", "emulator ", "ffmpeg "].contains {
                    command.command.hasPrefix($0)
                }
                #expect(leadsWithTool, "\(feature.id): unexpected command \"\(command.command)\"")
            }
        }
    }

    @Test func searchMatchesKeywordsAndTitle() {
        let logcat = FeatureRegistry.byID["logcat"]!
        #expect(logcat.matches("logs"))
        #expect(logcat.matches("LOGCAT"))
        #expect(!logcat.matches("battery"))
    }

    @Test func installParsesSuccessAndFailure() {
        let success = AppInstallService.parse(
            AdbResult(stdout: "Performing Streamed Install\nSuccess\n", stderr: "", exitCode: 0, timedOut: false))
        #expect(success.ok)

        let failure = AppInstallService.parse(AdbResult(
            stdout: "", stderr: "adb: failed to install app.apk: Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]",
            exitCode: 1, timedOut: false))
        #expect(!failure.ok)
        #expect(failure.message.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE"))
    }

    @Test func multiWordSearchMatchesNonContiguousTokens() {
        // "copy ip" must surface Copy Device IP even though "Device" sits between
        // the two words; it should outrank the Connection hub, whose subtitle
        // only mentions "Copy IP".
        let copyIP = FeatureRegistry.byID["get-ip"]!
        let connection = FeatureRegistry.byID["connection"]!
        #expect(copyIP.matches("copy ip"))
        #expect(copyIP.relevance(for: "copy ip") > connection.relevance(for: "copy ip"))
        // Every word still has to appear somewhere — gibberish doesn't match.
        #expect(!copyIP.matches("copy battery"))
    }

    @Test func hubsStaySearchableByTheirMembersPrimaryKeyword() {
        // Absorbed members no longer surface as standalone search results, so
        // each hub must carry its members' identity: searching a member's
        // primary keyword has to surface the hub, or that gathered feature
        // becomes undiscoverable.
        for (hubID, memberIDs) in FeatureRegistry.absorbedByHub {
            let hub = FeatureRegistry.byID[hubID]!
            for memberID in memberIDs {
                let member = FeatureRegistry.byID[memberID]!
                let primary = member.keywords.first ?? member.title
                #expect(
                    hub.matches(primary),
                    "hub \(hubID) should be searchable by \(memberID)'s keyword \"\(primary)\""
                )
            }
        }
    }

    @Test func layoutDefaultsExposeEnabledSet() {
        let layout = LayoutState()
        #expect(layout.effectiveEnabledIDs.contains("send-text"))
        #expect(layout.effectiveEnabledIDs.contains("custom-commands"))
        #expect(!layout.effectiveEnabledIDs.contains("fake-battery"))
    }

    @Test func everyRoleMapsValidFeatureIDsAndCoversTheCatalog() {
        for role in UserRole.allCases {
            for id in FeatureRegistry.featuresByRole[role] ?? [] {
                #expect(FeatureRegistry.byID[id] != nil, "role \(role.rawValue): unknown feature \(id)")
                #expect(
                    !(FeatureRegistry.byID[id]?.isAbsorbedByHub ?? false),
                    "role \(role.rawValue): \(id) is a hub member; reference its hub instead"
                )
            }
        }
        // Every non-system catalog feature must be reachable from some role, so
        // curation never orphans a feature. System features are always on
        // regardless of role, so they're exempt.
        let covered = Set(UserRole.allCases.flatMap { FeatureRegistry.featuresByRole[$0] ?? [] })
        let mustCover = Set(FeatureRegistry.catalogFeatureIDs)
            .subtracting(FeatureRegistry.systemFeatureIDs)
        #expect(mustCover.isSubset(of: covered), "uncovered catalog features: \(mustCover.subtracting(covered))")
    }

    @Test func seedRoleCuratesEnabledSetAndOrder() {
        var layout = LayoutState()
        layout.seedRole(.qaTester)
        let curated = FeatureRegistry.featureIDs(for: .qaTester)
        #expect(layout.selectedRole == UserRole.qaTester.rawValue)
        #expect(layout.roleChosen == true)
        #expect(layout.enabledIds == curated)
        #expect(layout.sidebarOrder == curated)
        #expect(layout.effectiveEnabledIDs.isSuperset(of: Set(curated)))
        #expect(layout.effectiveEnabledIDs.contains("custom-commands"))  // system stays on
        #expect(!layout.effectiveEnabledIDs.contains("wifi"))            // curated out for QA
        // The legacy migrations must not re-expand a curated role back to all-on.
        #expect(layout.adoptAllEnabled() == false)
        #expect(layout.adoptNewDefaults() == false)
        #expect(layout.enabledIds == curated)
    }

    @Test func flatOrderPersistsIndependentlyOfGroupedOrder() throws {
        var layout = LayoutState()
        layout.sidebarOrder = ["a", "b", "c"]
        layout.flatOrder = ["c", "a", "b"]
        let decoded = try JSONDecoder().decode(LayoutState.self, from: JSONEncoder().encode(layout))
        #expect(decoded.sidebarOrder == ["a", "b", "c"])
        #expect(decoded.flatOrder == ["c", "a", "b"])
        // A fresh layout has no flat order, so the flat sidebar mirrors the
        // grouped order until the user reorders it.
        #expect(LayoutState().flatOrder == nil)
    }

    @Test func adoptNewRoleFeaturesEnablesFeaturesAddedToTheRole() {
        var layout = LayoutState()
        layout.seedRole(.androidDeveloper)
        // Simulate a layout seeded before "emulators" joined the Android role.
        layout.enabledIds?.removeAll { $0 == "emulators" }
        layout.seededRoleIds?.removeAll { $0 == "emulators" }
        #expect(layout.enabledIds?.contains("emulators") == false)

        #expect(layout.adoptNewRoleFeatures() == true)
        #expect(layout.enabledIds?.contains("emulators") == true)
        // Idempotent once the baseline catches up.
        #expect(layout.adoptNewRoleFeatures() == false)

        // "Everything" users aren't role-curated — no-op.
        var everything = LayoutState()
        everything.seedEverything()
        #expect(everything.adoptNewRoleFeatures() == false)
    }

    @Test func seedEverythingLeavesEverythingOn() {
        var layout = LayoutState()
        layout.seedRole(.qaTester)
        layout.seedEverything()
        #expect(layout.roleChosen == true)
        #expect(layout.selectedRole == nil)
        #expect(layout.enabledIds == nil)
        #expect(Set(FeatureRegistry.catalogFeatureIDs).isSubset(of: layout.effectiveEnabledIDs))
    }
}
