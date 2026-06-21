import Foundation
import Testing
@testable import ADBKit

@Suite struct SidebarOrderingTests {
    // Other groups' ids (x, y, z) are interspersed; reordering the {a,b,c}
    // slice must leave them exactly where they were.
    private let full = ["a", "x", "b", "y", "c", "z"]
    private let slice = ["a", "b", "c"]

    @Test func reorderFirstItemToEndOfSlice() {
        let result = SidebarOrdering.reorder(displayed: slice, from: IndexSet(integer: 0), to: 3, within: full)
        #expect(result == ["b", "x", "c", "y", "a", "z"])
    }

    @Test func reorderLastItemToFrontOfSlice() {
        let result = SidebarOrdering.reorder(displayed: slice, from: IndexSet(integer: 2), to: 0, within: full)
        #expect(result == ["c", "x", "a", "y", "b", "z"])
    }

    @Test func reorderKeepsNonSliceIdsInPlace() {
        let result = SidebarOrdering.reorder(displayed: slice, from: IndexSet(integer: 1), to: 0, within: full)
        // x, y, z untouched at indices 1, 3, 5.
        #expect(Array(result.enumerated().filter { [1, 3, 5].contains($0.offset) }.map(\.element)) == ["x", "y", "z"])
    }

    @Test func reorderNoMoveReturnsSameOrder() {
        // Moving an item to its own position is a no-op.
        let result = SidebarOrdering.reorder(displayed: slice, from: IndexSet(integer: 1), to: 1, within: full)
        #expect(result == full)
    }

    @Test func moveCategoryBeforeAnother() {
        let order = ["input", "connection", "reactNative", "screen"]
        #expect(SidebarOrdering.move("screen", before: "connection", in: order)
            == ["input", "screen", "connection", "reactNative"])
    }

    @Test func moveCategoryToFront() {
        let order = ["input", "connection", "reactNative", "screen"]
        #expect(SidebarOrdering.move("screen", before: "input", in: order)
            == ["screen", "input", "connection", "reactNative"])
    }

    @Test func moveSameItemIsNoOp() {
        let order = ["a", "b", "c"]
        #expect(SidebarOrdering.move("b", before: "b", in: order) == order)
    }

    @Test func moveAbsentItemIsNoOp() {
        let order = ["a", "b", "c"]
        #expect(SidebarOrdering.move("zzz", before: "a", in: order) == order)
    }

    @Test func moveBeforeAbsentTargetAppends() {
        let order = ["a", "b", "c"]
        #expect(SidebarOrdering.move("a", before: "zzz", in: order) == ["b", "c", "a"])
    }

    @Test func moveToEndMovesItem() {
        #expect(SidebarOrdering.moveToEnd("a", in: ["a", "b", "c"]) == ["b", "c", "a"])
        #expect(SidebarOrdering.moveToEnd("c", in: ["a", "b", "c"]) == ["a", "b", "c"])
        #expect(SidebarOrdering.moveToEnd("zzz", in: ["a", "b", "c"]) == ["a", "b", "c"])
    }

    @Test func reorderToTopAndBottom() {
        // Drop a feature at the top of its group (toIndex 0) and at the end.
        #expect(SidebarOrdering.reorder(displayed: slice, from: IndexSet(integer: 2), to: 0, within: full)
            == ["c", "x", "a", "y", "b", "z"])
        #expect(SidebarOrdering.reorder(displayed: slice, from: IndexSet(integer: 0), to: 3, within: full)
            == ["b", "x", "c", "y", "a", "z"])
    }
}
