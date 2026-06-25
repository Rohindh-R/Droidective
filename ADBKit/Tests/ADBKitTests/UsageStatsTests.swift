import Foundation
import Testing
@testable import ADBKit

@Suite struct UsageStatsTests {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func recordIncrementsCountAndStampsLastUsed() {
        var stats = UsageStats()
        stats.record("logcat", at: date(100))
        stats.record("logcat", at: date(200))
        #expect(stats.count(for: "logcat") == 2)
        #expect(stats.byFeature["logcat"]?.lastUsed == date(200))
        #expect(stats.count(for: "screenshot") == 0)
    }

    @Test func rankPutsMostUsedFirstThenRecencyThenCuratedOrder() {
        var stats = UsageStats()
        // screenshot used most; logcat and apps tie on count, apps more recent.
        for t in [10.0, 20, 30] { stats.record("screenshot", at: date(t)) }
        stats.record("logcat", at: date(40))
        stats.record("apps", at: date(50))
        let curated = ["send-text", "logcat", "apps", "screenshot", "device-info"]
        #expect(stats.rank(curated) == ["screenshot", "apps", "logcat", "send-text", "device-info"])
    }

    @Test func rankPreservesCuratedOrderWhenUnused() {
        let stats = UsageStats()
        let curated = ["a", "b", "c", "d"]
        #expect(stats.rank(curated) == curated)
    }
}
