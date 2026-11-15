/// What changed between the rows a timeline shows and the rows the store
/// now holds. Rows are matched by merge key, which names a row on every
/// device and never changes, so a merged post keeps its identity when a new
/// copy joins it or the item it is shown from goes.
public struct TimelineDiff: Sendable, Equatable {
    /// The store's rows, in timeline order.
    public var rows: [TimelineRow]
    /// Indexes into `rows` of rows the timeline hasn't shown before.
    public var inserted: [Int]
    /// Indexes into `rows` of rows whose content changed, such as a new boost.
    public var changed: [Int]
    /// Merge keys of rows the timeline showed that are gone (pruned, or their
    /// source removed).
    public var removed: [String]
    /// How many inserted rows come after every row the timeline already had:
    /// newer rows arriving at the bottom, which the "N newer" pill counts.
    public var appendedAtEnd: Int
    /// Whether rows both lists hold are in a different order.
    public var reordered: Bool

    public var isEmpty: Bool { inserted.isEmpty && changed.isEmpty && removed.isEmpty && !reordered }

    public init(from old: [TimelineRow], to new: [TimelineRow]) {
        var oldByKey: [String: TimelineRow] = [:]
        oldByKey.reserveCapacity(old.count)
        for row in old { oldByKey[row.mergeKey] = row }

        var inserted: [Int] = []
        var changed: [Int] = []
        var lastKept = -1
        var newKeys = Set<String>()
        newKeys.reserveCapacity(new.count)
        for (index, row) in new.enumerated() {
            newKeys.insert(row.mergeKey)
            if let previous = oldByKey[row.mergeKey] {
                lastKept = index
                if previous != row { changed.append(index) }
            } else {
                inserted.append(index)
            }
        }

        rows = new
        self.inserted = inserted
        self.changed = changed
        removed = old.map(\.mergeKey).filter { !newKeys.contains($0) }
        appendedAtEnd = old.isEmpty ? 0 : inserted.count(where: { $0 > lastKept })
        let keptInOldOrder = old.lazy.map(\.mergeKey).filter { newKeys.contains($0) }
        let keptInNewOrder = new.lazy.map(\.mergeKey).filter { oldByKey[$0] != nil }
        reordered = !keptInOldOrder.elementsEqual(keptInNewOrder)
    }
}
