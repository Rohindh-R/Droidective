import Foundation

/// Pure ordering math for the reorderable sidebar and catalog. Kept out of the
/// SwiftUI layer so the slice-remapping (drag a row within its group) and
/// category moves (drag a whole group) are unit-tested without a UI or a device.
public enum SidebarOrdering {
    /// Apply a drag-reorder of a displayed slice back onto the global order.
    ///
    /// `displayed` is exactly the list the reordered view showed (a subset of
    /// `fullOrder`, in display order). The move is applied within that slice,
    /// then the new sequence is written back into `fullOrder` in the slots the
    /// displayed ids already occupied — so ids outside the slice (other groups,
    /// disabled features) keep their positions.
    public static func reorder(
        displayed: [String], from source: IndexSet, to destination: Int, within fullOrder: [String]
    ) -> [String] {
        let moved = applyMove(displayed, from: source, to: destination)
        let slice = Set(displayed)
        var queue = moved
        var result: [String] = []
        for id in fullOrder {
            result.append(slice.contains(id) && !queue.isEmpty ? queue.removeFirst() : id)
        }
        return result
    }

    /// `Collection.move(fromOffsets:toOffset:)` lives in SwiftUI, which this
    /// package can't import — so reproduce its semantics: `destination` is the
    /// insertion index in the original array (0...count).
    static func applyMove(_ array: [String], from source: IndexSet, to destination: Int) -> [String] {
        let moving = source.sorted().map { array[$0] }
        var result = array
        for index in source.sorted(by: >) {
            result.remove(at: index)
        }
        let insertAt = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: insertAt)
        return result
    }

    /// Move `item` so it sits immediately before `target` in `order`. A no-op
    /// when `item == target` or `item` isn't present; appends to the end if
    /// `target` isn't present.
    public static func move(_ item: String, before target: String, in order: [String]) -> [String] {
        guard item != target, let from = order.firstIndex(of: item) else { return order }
        var result = order
        result.remove(at: from)
        if let to = result.firstIndex(of: target) {
            result.insert(item, at: to)
        } else {
            result.append(item)
        }
        return result
    }

    /// Move `item` to the end of `order`. No-op if absent.
    public static func moveToEnd(_ item: String, in order: [String]) -> [String] {
        guard let from = order.firstIndex(of: item) else { return order }
        var result = order
        result.remove(at: from)
        result.append(item)
        return result
    }
}
