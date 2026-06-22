import Testing
@testable import ADBKit

@Suite struct SystemAppsServiceTests {
    @Test func parsePackageListStripsPrefixAndUid() {
        let set = SystemAppsService.parsePackageList("""
        package:com.android.chrome
        package:com.google.android.youtube uid:10123
        not-a-package-line
        package:
        """)
        #expect(set == ["com.android.chrome", "com.google.android.youtube"])
    }

    @Test func lifecycleMapMarksDisabledAndRemoved() {
        let map = SystemAppsService.lifecycleMap(
            installed: ["com.a", "com.b"],
            disabled: ["com.b"],
            known: ["com.a", "com.b", "com.c"]
        )
        #expect(map["com.a"] == AppLifecycle(disabled: false, removed: false))
        #expect(map["com.b"] == AppLifecycle(disabled: true, removed: false))
        #expect(map["com.c"] == AppLifecycle(disabled: false, removed: true))
        #expect(map["com.c"]?.label == "Removed")
    }

    @Test func uninstallOutcomeTreatsAbsentPackageAsRemoved() {
        // A user app fully uninstalled drops out of the lifecycle map entirely;
        // that's success, not a protected-package failure.
        #expect(SystemAppsService.uninstallOutcome(for: nil) == .removed)
        #expect(SystemAppsService.uninstallOutcome(
            for: AppLifecycle(disabled: false, removed: true)) == .removedForUser)
        #expect(SystemAppsService.uninstallOutcome(
            for: AppLifecycle(disabled: false, removed: false)) == .stillInstalled)
        #expect(SystemAppsService.uninstallOutcome(
            for: AppLifecycle(disabled: true, removed: false)) == .stillInstalled)
    }
}
