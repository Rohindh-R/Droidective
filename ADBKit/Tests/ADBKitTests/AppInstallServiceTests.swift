import Foundation
import Testing
@testable import ADBKit

@Suite struct AppInstallServiceTests {
    private func result(_ stdout: String, _ stderr: String = "") -> AdbResult {
        AdbResult(stdout: stdout, stderr: stderr, exitCode: 0, timedOut: false)
    }

    @Test func successIsInstalled() {
        let r = AppInstallService.parse(result("Success\n"))
        #expect(r.ok)
        #expect(r.message == "Installed")
    }

    @Test func knownFailureCodeBecomesPlainEnglish() {
        let raw = "Performing Streamed Install\nFailure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"
        let r = AppInstallService.parse(result("", raw))
        #expect(!r.ok)
        #expect(r.message == "Not enough storage on the device.")
        // The full adb output is kept for the notifications panel.
        #expect(r.copyText?.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") == true)
    }

    @Test func signatureMismatchIsExplained() {
        let r = AppInstallService.parse(result("", "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"))
        #expect(r.message.contains("uninstall it first"))
    }

    @Test func unmappedCodeIsSurfacedRaw() {
        let r = AppInstallService.parse(result("", "Failure [INSTALL_FAILED_CONTAINER_ERROR]"))
        #expect(r.message == "INSTALL_FAILED_CONTAINER_ERROR")
        #expect(r.copyText?.contains("INSTALL_FAILED_CONTAINER_ERROR") == true)
    }

    @Test func unrecognizedErrorUsesLastLineAndKeepsFullOutput() {
        let raw = "Performing Streamed Install\nadb: failed to install app.apk: weird device error"
        let r = AppInstallService.parse(result("", raw))
        #expect(!r.ok)
        #expect(r.message == "adb: failed to install app.apk: weird device error")
        #expect(r.copyText == raw)
    }

    @Test func friendlyReasonMapsCommonCodes() {
        #expect(AppInstallService.friendlyReason("INSTALL_FAILED_ALREADY_EXISTS") == "The app is already installed.")
        #expect(AppInstallService.friendlyReason("INSTALL_FAILED_NO_MATCHING_ABIS").contains("CPU"))
    }

    @Test func parseFailureCodeGetsItsOwnMessage() {
        let r = AppInstallService.parse(result("", "Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES]"))
        #expect(!r.ok)
        #expect(r.message.contains("couldn't be parsed"))
        #expect(r.copyText?.contains("INSTALL_PARSE_FAILED_NO_CERTIFICATES") == true)
    }

    @Test func emptyOutputIsUnknownErrorWithNoCopyText() {
        let r = AppInstallService.parse(result("", ""))
        #expect(!r.ok)
        #expect(r.message == "Unknown error.")
        #expect(r.copyText == nil)
    }

    @Test func failureMentioningTheWordSuccessIsNotMisreadAsSuccess() {
        // The word appears mid-line in a failure — it must not be read as the
        // bare `Success` line adb prints on a real install.
        let r = AppInstallService.parse(result("", "Failure [INSTALL_FAILED_INVALID_APK]: not successful"))
        #expect(!r.ok)
        #expect(r.message == "The APK is invalid or corrupt.")
    }
}
