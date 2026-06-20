import Testing
@testable import ADBKit

@Suite struct RestrictionsServiceTests {
    @Test func defaultsWhenUnset() {
        let state = RestrictionsService.parseState(
            adbInstall: "null", packageVerifier: "null", stayAwake: "null",
            hiddenApi: "null", getenforce: "Enforcing"
        )
        #expect(state.adbInstallVerification)   // default 1
        #expect(state.packageVerifier)          // default 1
        #expect(!state.stayAwake)               // default 0
        #expect(state.hiddenApiEnforced)        // unset = enforced
        #expect(state.selinuxEnforcing == true)
    }

    @Test func bypassedValues() {
        let state = RestrictionsService.parseState(
            adbInstall: "0", packageVerifier: "0", stayAwake: "7",
            hiddenApi: "1", getenforce: "Permissive"
        )
        #expect(!state.adbInstallVerification)
        #expect(!state.packageVerifier)
        #expect(state.stayAwake)
        #expect(!state.hiddenApiEnforced)       // 1 = enforcement disabled
        #expect(state.selinuxEnforcing == false)
    }

    @Test func unknownSelinux() {
        let state = RestrictionsService.parseState(
            adbInstall: "1", packageVerifier: "1", stayAwake: "0",
            hiddenApi: "0", getenforce: "/system/bin/sh: getenforce: not found"
        )
        #expect(state.selinuxEnforcing == nil)
    }
}
