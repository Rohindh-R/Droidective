import Testing
@testable import ADBKit

@Suite struct DnsServiceTests {
    @Test func parsesOff() {
        let status = DnsService.parse(mode: "off", specifier: "null")
        #expect(status.mode == .off)
        #expect(status.hostname == nil)
    }

    @Test func parsesHostname() {
        let status = DnsService.parse(mode: "hostname", specifier: "dns.google")
        #expect(status.mode == .hostname)
        #expect(status.hostname == "dns.google")
    }

    @Test func opportunisticAndUnsetMapToAutomatic() {
        #expect(DnsService.parse(mode: "opportunistic", specifier: "null").mode == .automatic)
        #expect(DnsService.parse(mode: "null", specifier: "").mode == .automatic)
        #expect(DnsService.parse(mode: "", specifier: "").mode == .automatic)
    }
}
