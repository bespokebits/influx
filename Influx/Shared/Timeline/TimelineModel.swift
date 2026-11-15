// The rows on screen, their geometry, and each row's offset from the top.
// The layout reads it and never measures anything, so it costs the same for
// any number of rows.
import CoreGraphics
import InfluxKit

@MainActor
final class TimelineModel {
    private(set) var rows: [TimelineRow] = []
    private(set) var geometries: [RowGeometry] = []
    private(set) var offsets: [CGFloat] = []
    private(set) var totalHeight: CGFloat = 0
    private var indexByKey: [String: Int] = [:]
    /// Goes up whenever the rows change, so Find in Timeline knows when the
    /// rows it made ready to search are out of date.
    private(set) var version = 0
    /// Called after the rows change, for Find in Timeline to search again.
    var onReplace: (() -> Void)?

    var count: Int { rows.count }
    var keys: [String] { rows.map(\.mergeKey) }

    func replace(_ newRows: [TimelineRow], geometries newGeometries: [RowGeometry]) {
        precondition(newRows.count == newGeometries.count)
        rows = newRows
        geometries = newGeometries
        version += 1
        offsets.removeAll(keepingCapacity: true)
        offsets.reserveCapacity(newRows.count)
        indexByKey.removeAll(keepingCapacity: true)
        totalHeight = 0
        for (index, row) in newRows.enumerated() {
            offsets.append(totalHeight)
            totalHeight += newGeometries[index].height
            indexByKey[row.mergeKey] = index
        }
        onReplace?()
    }

    func index(of key: String) -> Int? {
        indexByKey[key]
    }

    /// The last row whose top is at or above `y`.
    func row(at y: CGFloat) -> Int {
        var low = 0
        var high = offsets.count - 1
        guard high >= 0 else { return 0 }
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The rows that overlap `top..<top + height`.
    func rows(in top: CGFloat, height: CGFloat) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        return row(at: top)..<(row(at: top + height) + 1)
    }

    func frame(ofRow index: Int) -> CGRect {
        CGRect(x: 0, y: offsets[index], width: geometries[index].width, height: geometries[index].height)
    }
}
