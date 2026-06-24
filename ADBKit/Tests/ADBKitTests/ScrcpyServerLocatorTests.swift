import Foundation
import Testing
@testable import ADBKit

@Suite struct ScrcpyServerLocatorTests {
    @Test func derivesJarPathFromHomebrewBinary() {
        #expect(ScrcpyServerLocator.jarPath(forBinary: "/opt/homebrew/bin/scrcpy")
            == "/opt/homebrew/share/scrcpy/scrcpy-server")
        #expect(ScrcpyServerLocator.jarPath(forBinary: "/usr/local/bin/scrcpy")
            == "/usr/local/share/scrcpy/scrcpy-server")
    }

    @Test func parsesVersionFromBanner() {
        #expect(ScrcpyServerLocator.parseVersion("scrcpy 4.0 <https://github.com/Genymobile/scrcpy>") == "4.0")
        // The real banner is multi-line; the version is on the first line.
        #expect(ScrcpyServerLocator.parseVersion("scrcpy 2.7\nDependencies (compiled / linked):") == "2.7")
    }

    @Test func returnsNilForUnparseableBanner() {
        #expect(ScrcpyServerLocator.parseVersion("") == nil)
        #expect(ScrcpyServerLocator.parseVersion("not scrcpy output") == nil)
        #expect(ScrcpyServerLocator.parseVersion("scrcpy") == nil)
    }
}
