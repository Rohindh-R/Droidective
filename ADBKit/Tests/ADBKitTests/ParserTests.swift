import Testing
@testable import ADBKit

@Suite struct GetpropParserTests {
    @Test func parsesPropDump() {
        let output = """
        [ro.product.model]: [Pixel 7]
        [ro.build.version.release]: [14]
        [ro.empty]: []
        not a prop line
        """
        let props = DeviceProps.parse(output)
        #expect(props["ro.product.model"] == "Pixel 7")
        #expect(props["ro.build.version.release"] == "14")
        #expect(props["ro.empty"] == "")
        #expect(props.count == 3)
    }
}

@Suite struct IpParseTests {
    @Test func parsesInetAddress() {
        let output = """
        30: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
            inet 192.168.1.42/24 brd 192.168.1.255 scope global wlan0
        """
        #expect(FeatureEngine.parseIP(output) == "192.168.1.42")
    }

    @Test func parsesRouteSrcFallback() {
        let output = "default via 192.168.1.1 dev wlan0 proto dhcp src 10.0.0.7 metric 600"
        #expect(FeatureEngine.parseIP(output) == "10.0.0.7")
    }

    @Test func returnsNilWhenNoIP() {
        #expect(FeatureEngine.parseIP("wlan0: no address") == nil)
    }
}

@Suite struct TextInputEscapingTests {
    @Test func escapesSpacesAsPercentS() {
        #expect(TextInputService.escapeForInput("hello world") == "hello%sworld")
    }

    @Test func escapesShellMetacharacters() {
        #expect(TextInputService.escapeForInput("a\"b") == "a\\\"b")
        #expect(TextInputService.escapeForInput("$(rm)") == "\\$\\(rm\\)")
        #expect(TextInputService.escapeForInput("a&b|c;d") == "a\\&b\\|c\\;d")
    }

    @Test func leavesPlainTextAlone() {
        #expect(TextInputService.escapeForInput("hello123") == "hello123")
    }
}

@Suite struct ShellQuoteTests {
    @Test func quotesUrlMetacharacters() {
        #expect(shellQuote("myapp://x?a=1&b=2") == "'myapp://x?a=1&b=2'")
        #expect(shellQuote("/data/local/My File.txt") == "'/data/local/My File.txt'")
    }

    @Test func escapesEmbeddedSingleQuotes() {
        #expect(shellQuote("it's") == "'it'\\''s'")
    }
}

@Suite struct FriendlyErrorTests {
    private func result(stderr: String, timedOut: Bool = false) -> AdbResult {
        AdbResult(stdout: "", stderr: stderr, exitCode: 1, timedOut: timedOut)
    }

    @Test func mapsKnownErrors() {
        #expect(friendlyAdbError(result(stderr: "error: no devices/emulators found"), fallback: "f") == "No device connected.")
        #expect(friendlyAdbError(result(stderr: "adb: device offline"), fallback: "f") == "Device is offline.")
        #expect(friendlyAdbError(result(stderr: "error: device unauthorized."), fallback: "f")
            == "Device is unauthorized — accept the USB debugging prompt.")
        #expect(friendlyAdbError(result(stderr: "adb: more than one device/emulator"), fallback: "f")
            == "Multiple devices — pick a target device.")
    }

    @Test func timeoutWinsOverStderr() {
        #expect(friendlyAdbError(result(stderr: "no devices", timedOut: true), fallback: "f") == "The command timed out.")
    }

    @Test func fallsBackToTrimmedStderrThenFallback() {
        #expect(friendlyAdbError(result(stderr: "  weird failure \n"), fallback: "f") == "weird failure")
        #expect(friendlyAdbError(result(stderr: "   "), fallback: "the fallback") == "the fallback")
    }
}
