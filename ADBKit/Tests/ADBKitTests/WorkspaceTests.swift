import Foundation
import Testing
@testable import ADBKit

@Suite struct WorkspaceTests {
    private func make(_ groups: [[String]], focused: Int = 0) -> Workspace {
        Workspace(
            restoring: groups.map { TabGroupState(tabs: $0, activeTab: $0.first) },
            focusedGroup: focused,
            fallback: "home",
            isValidID: { _ in true }
        )
    }

    // MARK: - open / focus-or-create + cap

    @Test func opensNewTabsInTheFocusedPane() {
        var ws = Workspace(fallback: "home")
        let ok = ws.open("logcat")
        #expect(ok)
        #expect(ws.openTabs(inGroup: 0) == ["home", "logcat"])
        #expect(ws.activeTab == "logcat")
    }

    @Test func openingATabInTheOtherPaneFocusesThatPane() {
        var ws = make([["home", "logcat"], ["performance"]], focused: 0)
        let ok = ws.open("performance") // lives in pane 1
        #expect(ok)
        #expect(ws.focusedGroup == 1)
        #expect(ws.activeTab == "performance")
    }

    @Test func openRefusesANewTabAtTheTotalCapButStillRefocuses() {
        let first = (0..<6).map { "a\($0)" }
        let second = (0..<4).map { "b\($0)" } // 6 + 4 = 10 total (the cap)
        var ws = make([first, second], focused: 0)
        #expect(ws.totalTabs == Workspace.maxTabs)
        let blocked = ws.open("overflow")
        #expect(blocked == false)
        #expect(ws.totalTabs == Workspace.maxTabs) // nothing added
        let refocus = ws.open("b0") // already open → allowed
        #expect(refocus)
        #expect(ws.focusedGroup == 1)
    }

    // MARK: - close / collapse / never-empty

    @Test func closingTheLastTabReopensTheFallback() {
        var ws = Workspace(fallback: "home")
        ws.close("home")
        #expect(ws.groups.count == 1)
        #expect(ws.openTabs(inGroup: 0) == ["home"]) // never empty
    }

    @Test func closingASecondPanesLastTabCollapsesTheSplit() {
        var ws = make([["home", "logcat"], ["performance"]], focused: 1)
        ws.close("performance")
        #expect(ws.isSplit == false)
        #expect(ws.openTabs(inGroup: 0) == ["home", "logcat"])
        #expect(ws.focusedGroup == 0) // clamped back into range
    }

    @Test func closingTheFirstPanesLastTabPromotesTheOther() {
        var ws = make([["home"], ["logcat", "performance"]], focused: 0)
        ws.close("home")
        #expect(ws.isSplit == false)
        #expect(ws.openTabs(inGroup: 0) == ["logcat", "performance"])
        #expect(ws.focusedGroup == 0)
    }

    // MARK: - move / split

    @Test func moveAcrossPanesCollapsesTheEmptiedSourceAndFollowsFocus() {
        var ws = make([["home"], ["logcat", "performance"]], focused: 1)
        ws.move("home", toGroup: 1) // source (pane 0) empties → collapses
        #expect(ws.isSplit == false)
        #expect(Set(ws.openTabs(inGroup: 0)) == ["home", "logcat", "performance"])
        #expect(ws.focusedGroup == 0)
        #expect(ws.activeTab == "home") // moved tab is active in its new pane
    }

    @Test func moveKeepsBothPanesWhenSourceStillHasTabs() {
        var ws = make([["home", "logcat"], ["performance"]], focused: 0)
        ws.move("logcat", toGroup: 1)
        #expect(ws.openTabs(inGroup: 0) == ["home"])
        #expect(ws.openTabs(inGroup: 1) == ["performance", "logcat"])
        #expect(ws.focusedGroup == 1)
    }

    @Test func splitMovesATabIntoANewPaneButNeedsSomethingToLeaveBehind() {
        var ws = make([["home", "logcat"]])
        ws.split("logcat")
        #expect(ws.isSplit)
        #expect(ws.openTabs(inGroup: 0) == ["home"])
        #expect(ws.openTabs(inGroup: 1) == ["logcat"])
        #expect(ws.focusedGroup == 1)
    }

    @Test func splitIsANoOpForALoneTabOrWhenAlreadySplit() {
        var lone = make([["home"]])
        lone.split("home")
        #expect(lone.isSplit == false) // nothing would be left behind

        var alreadySplit = make([["home", "logcat"], ["performance"]])
        alreadySplit.split("logcat")
        #expect(alreadySplit.groups.count == 2) // no third pane
    }

    // MARK: - reorder / drop

    @Test func dropReordersWithinTheSamePane() {
        var ws = make([["a", "b", "c"]])
        ws.drop("a", intoGroup: 0, before: "c")
        #expect(ws.openTabs(inGroup: 0) == ["b", "a", "c"])
    }

    @Test func dropAcrossPanesMovesAndPositions() {
        var ws = make([["home", "logcat"], ["x", "y"]], focused: 0)
        ws.drop("logcat", intoGroup: 1, before: "y")
        #expect(ws.openTabs(inGroup: 0) == ["home"])
        #expect(ws.openTabs(inGroup: 1) == ["x", "logcat", "y"])
    }

    // MARK: - cycle only touches the focused pane

    @Test func cycleStaysWithinTheFocusedPane() {
        var ws = make([["a", "b"], ["x", "y", "z"]], focused: 1)
        ws.cycleForward() // pane 1 active was x → y
        #expect(ws.activeTab == "y")
        #expect(ws.activeTab(inGroup: 0) == "a") // other pane untouched
    }

    // MARK: - restore invariants

    @Test func restoreDedupesIdsAcrossPanes() {
        let ws = make([["home", "logcat"], ["logcat", "performance"]])
        // "logcat" kept only in the first pane.
        #expect(ws.openTabs(inGroup: 0) == ["home", "logcat"])
        #expect(ws.openTabs(inGroup: 1) == ["performance"])
    }

    @Test func restoreTrimsToTheTotalCapAndTwoPanes() {
        let groups = [
            (0..<8).map { "a\($0)" },
            (0..<8).map { "b\($0)" },
            ["c0"], // third pane dropped entirely
        ]
        let ws = make(groups)
        #expect(ws.groups.count == 2)
        #expect(ws.totalTabs == Workspace.maxTabs) // 8 + 2, trimmed
        #expect(ws.openTabs(inGroup: 0).count == 8)
        #expect(ws.openTabs(inGroup: 1).count == 2)
    }

    @Test func restoreDropsInvalidIdsAndSeedsFallbackWhenNothingSurvives() {
        let ws = Workspace(
            restoring: [TabGroupState(tabs: ["ghost", "gone"], activeTab: "ghost")],
            focusedGroup: 5,
            fallback: "home",
            isValidID: { $0 == "home" } // nothing valid survives
        )
        #expect(ws.openTabs(inGroup: 0) == ["home"])
        #expect(ws.focusedGroup == 0) // out-of-range focus clamped
    }

    @Test func resetCollapsesToASingleFallbackPane() {
        var ws = make([["home", "logcat"], ["performance"]], focused: 1)
        ws.reset()
        #expect(ws.groups.count == 1)
        #expect(ws.openTabs(inGroup: 0) == ["home"])
        #expect(ws.focusedGroup == 0)
    }
}
