/// Which row a timeline holds still on the screen when its rows change.
///
/// Rows arrive, go and change above the reader all the time, and the
/// timeline keeps one row where it was on the screen so the reader doesn't
/// see any of it. That row was always the one at the top. But sync can move
/// a row: two devices that placed a post differently settle on one position
/// (ADR 0016), and the row goes there on the device that had it elsewhere.
/// Holding a row that moved takes the screen with it, so a reader whose top
/// row was moved hours up the timeline found themselves among posts they
/// had read long before (influx-dev #125). A row that moved isn't where the
/// reader is; the rows around it that stayed are.
public enum HeldRow {
    /// How many rows below the screen, and then above it, are tried when
    /// every row on it has moved or gone.
    public static let reach = 200

    /// The index in `rows`, the rows as they were shown, of the row to hold
    /// through a change: the first of the `visible` rows, from the top, that
    /// is still where it was. When none of them is, the nearest row below
    /// the screen that is, and then the nearest above. Nil when there's no
    /// such row within reach, or no rows.
    ///
    /// `now` gives the row with a merge key as the store has it now, or nil
    /// if it has gone. A row is where it was when its position is the same:
    /// rows arriving or going elsewhere change its index, not its position.
    public static func choose(in rows: [TimelineRow], visible: Range<Int>, now: (String) -> TimelineRow?) -> Int? {
        let visible = visible.clamped(to: rows.indices)
        func stayed(_ index: Int) -> Bool {
            now(rows[index].mergeKey)?.sortDate == rows[index].sortDate
        }
        if let index = visible.first(where: stayed) { return index }
        let below = visible.upperBound..<min(rows.count, visible.upperBound + reach)
        if let index = below.first(where: stayed) { return index }
        let above = max(0, visible.lowerBound - reach)..<visible.lowerBound
        return above.last(where: stayed)
    }
}
