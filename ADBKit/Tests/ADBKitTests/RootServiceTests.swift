import Testing
@testable import ADBKit

@Suite struct RootServiceTests {
    private static let cleanProps = [
        "ro.build.tags": "release-keys",
        "ro.debuggable": "0",
        "ro.secure": "1",
    ]

    @Test func rootedWhenSuShellReturnsUidZero() {
        let status = RootService.evaluate(
            idOutput: "uid=0(root) gid=0(root) groups=0(root) context=u:r:su:s0",
            whichSu: "/system/xbin/su",
            suList: "/system/xbin/su",
            magiskList: "",
            props: Self.cleanProps,
            getenforce: "Enforcing"
        )
        #expect(status.hasRootShell)
        #expect(status.likelyRooted)
        #expect(status.summary.hasPrefix("Rooted"))
    }

    @Test func notRootedOnCleanProductionDevice() {
        let status = RootService.evaluate(
            idOutput: "uid=2000(shell) gid=2000(shell) groups=2000(shell)",
            whichSu: "",
            suList: "ls: /system/bin/su: No such file or directory",
            magiskList: "ls: /sbin/.magisk: No such file or directory",
            props: Self.cleanProps,
            getenforce: "Enforcing"
        )
        #expect(!status.hasRootShell)
        #expect(!status.likelyRooted)
        #expect(status.summary == "Not rooted")
    }

    @Test func magiskFlagsLikelyRootedEvenWithoutShell() {
        let status = RootService.evaluate(
            idOutput: "uid=2000(shell)",
            whichSu: "",
            suList: "",
            magiskList: "/data/adb/magisk",
            props: Self.cleanProps,
            getenforce: "Permissive"
        )
        #expect(!status.hasRootShell)
        #expect(status.likelyRooted)
        #expect(status.summary.contains("Magisk"))
    }

    @Test func suBinaryWithoutGrantedShellIsLikelyRooted() {
        let status = RootService.evaluate(
            idOutput: "",
            whichSu: "/system/xbin/su",
            suList: "",
            magiskList: "",
            props: Self.cleanProps,
            getenforce: "Enforcing"
        )
        #expect(!status.hasRootShell)
        #expect(status.likelyRooted)
        #expect(status.summary.contains("su binary"))
    }

    @Test func anyPathExistsIgnoresErrorLines() {
        #expect(RootService.anyPathExists("/system/bin/su"))
        #expect(RootService.anyPathExists("/data/adb/magisk\n/data/adb/modules"))
        #expect(!RootService.anyPathExists("ls: /system/bin/su: No such file or directory"))
        #expect(!RootService.anyPathExists(""))
    }
}
