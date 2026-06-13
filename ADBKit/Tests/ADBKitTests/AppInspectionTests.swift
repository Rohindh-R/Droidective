import Testing
@testable import ADBKit

@Suite struct PermissionParsingTests {
    @Test func parsesRuntimePermissionBlock() {
        let dump = """
        Packages:
          Package [com.app] (abc):
            runtime permissions:
              android.permission.CAMERA: granted=true, flags=[ USER_SET]
              android.permission.RECORD_AUDIO: granted=false, flags=[ USER_SET]

            enabled components:
        """
        let permissions = AppInspectionService.parsePermissions(dump)
        #expect(permissions.count == 2)
        #expect(permissions[0].name == "android.permission.CAMERA")
        #expect(permissions[0].granted)
        #expect(permissions[0].shortName == "CAMERA")
        #expect(!permissions[1].granted)
    }

    @Test func noRuntimeBlockYieldsEmpty() {
        #expect(AppInspectionService.parsePermissions("Packages:\n  nothing here").isEmpty)
    }
}

@Suite struct AppInfoParsingTests {
    @Test func parsesVersionFields() {
        let dump = """
        Package [com.app] (1234):
            versionCode=421 minSdk=24 targetSdk=34
            versionName=2.4.1
            firstInstallTime=2024-01-15 10:00:00
            lastUpdateTime=2025-11-01 09:30:00
        """
        let info = AppInspectionService.parseAppInfo(dump, packageId: "com.app")
        #expect(info.installed)
        #expect(info.versionName == "2.4.1")
        #expect(info.versionCode == "421")
        #expect(info.targetSdk == "34")
        #expect(info.minSdk == "24")
        #expect(info.firstInstall == "2024-01-15 10:00:00")
    }

    @Test func missingPackageReportsNotInstalled() {
        let info = AppInspectionService.parseAppInfo("Unable to find package: com.app", packageId: "com.other")
        #expect(!info.installed)
    }
}

@Suite struct ForegroundActivityParsingTests {
    @Test func parsesResumedActivity() {
        let dump = """
          mResumedActivity: ActivityRecord{abc123 u0 com.myapp/.MainActivity t42}
        """
        #expect(AppInspectionService.parseResumedActivity(dump) == "com.myapp/.MainActivity")
    }

    @Test func parsesTopResumedVariant() {
        let dump = "topResumedActivity=ActivityRecord{def456 u0 com.other/com.other.ui.HomeActivity t7}"
        #expect(AppInspectionService.parseResumedActivity(dump) == "com.other/com.other.ui.HomeActivity")
    }

    @Test func missingActivityReturnsNil() {
        #expect(AppInspectionService.parseResumedActivity("nothing useful") == nil)
    }
}

@Suite struct MemInfoParsingTests {
    @Test func parsesTotalAndSummary() {
        let output = """
        Applications Memory Usage (in Kilobytes):
        ** MEMINFO in pid 1234 [com.app] **
                 Native Heap    25000
                 Dalvik Heap    18000
                       TOTAL    98765
        """
        let info = AppInspectionService.parseMemInfo(output)
        #expect(info.running)
        #expect(info.totalPssKb == 98765)
        #expect(info.summary.contains { $0.key == "Native Heap" && $0.value == "25000" })
    }

    @Test func noProcessMeansNotRunning() {
        let info = AppInspectionService.parseMemInfo("No process found for: com.app")
        #expect(!info.running)
        #expect(info.totalPssKb == nil)
    }
}

@Suite struct SandboxParsingTests {
    @Test func parsesLsOutputDirsFirst() {
        let output = """
        total 48
        drwxrws--x  5 u0_a123 u0_a123 4096 2025-06-01 10:00 .
        drwx------ 41 u0_a123 u0_a123 4096 2025-06-01 10:00 ..
        -rw-------  1 u0_a123 u0_a123  1234 2025-06-01 10:00 app.db
        drwxrws--x  2 u0_a123 u0_a123 4096 2025-06-01 10:00 shared_prefs
        -rw-------  1 u0_a123 u0_a123    99 2025-06-01 10:00 my file.txt
        """
        let entries = AppInspectionService.parseLsOutput(output)
        #expect(entries.map(\.name) == ["shared_prefs", "app.db", "my file.txt"])
        #expect(entries[0].isDir)
        #expect(entries[1].size == 1234)
    }

    @Test func detectsNotDebuggable() {
        #expect(AppInspectionService.isNotDebuggable("run-as: package not debuggable: com.app"))
        #expect(AppInspectionService.isNotDebuggable("run-as: Could not set capabilities: not an application"))
        #expect(!AppInspectionService.isNotDebuggable(""))
    }
}
