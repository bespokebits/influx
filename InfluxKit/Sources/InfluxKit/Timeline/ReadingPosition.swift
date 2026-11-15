import Foundation

/// Where the reader of a saved view is. The view's last-read marker is the
/// newest row they have scrolled past, and the timeline opens on the row
/// after it.
public enum ReadingPosition {
    /// The one view the v1 timeline shows: every source.
    public static let allViewID = "all"

    /// The index of the first row after `marker` in `rows`, which are in
    /// timeline order, or nil when no row comes after it. The marker's own
    /// row needn't be there, since pruning may have removed it.
    public static func firstRow(after marker: LastReadMarker, in rows: [TimelineRow]) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if isAfter(rows[mid], marker) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low < rows.count ? low : nil
    }

    /// Whether `row` comes after `marker` in timeline order: by date, then
    /// by merge key compared as UTF-8 bytes, as the store orders rows.
    public static func isAfter(_ row: TimelineRow, _ marker: LastReadMarker) -> Bool {
        if row.sortDate != marker.sortDate {
            return row.sortDate > marker.sortDate
        }
        return marker.mergeKey.utf8.lexicographicallyPrecedes(row.mergeKey.utf8)
    }

    /// The row a timeline opens with at the top of the screen: the reading
    /// place's, or else the first row after `marker`; nil for the newest
    /// rows, when there's neither or nothing after the marker.
    public static func openingRow(in rows: [TimelineRow], place: ReadingPlace?, marker: LastReadMarker?) -> Int? {
        if let place, let index = row(at: place, in: rows) {
            return index
        }
        return marker.flatMap { firstRow(after: $0, in: rows) }
    }

    /// How a device's rows stand for a reading place.
    public enum Standing: Sendable, Hashable {
        /// The place's own row is here.
        case ownRow
        /// The row isn't here; the first row at or after its date stands in.
        case standIn
        /// The row isn't here, and every row here is before its date: the
        /// last row stands in, and the reader hasn't reached the place.
        case pastTheEnd
    }

    /// The row that stands for `place` in `rows`, which are in timeline
    /// order, and how. Nil when there are no rows.
    public static func find(_ place: ReadingPlace, in rows: [TimelineRow]) -> (index: Int, standing: Standing)? {
        guard !rows.isEmpty else { return nil }
        if let index = rows.firstIndex(where: { $0.mergeKey == place.mergeKey }) {
            return (index, .ownRow)
        }
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].sortDate >= place.sortDate {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low < rows.count ? (low, .standIn) : (rows.count - 1, .pastTheEnd)
    }

    /// The index of the row a reading place names in `rows`, which are in
    /// timeline order: its own row, or, when this device doesn't have it,
    /// the first row at or after its date, or the last row. Nil when there
    /// are no rows.
    public static func row(at place: ReadingPlace, in rows: [TimelineRow]) -> Int? {
        find(place, in: rows)?.index
    }
}
