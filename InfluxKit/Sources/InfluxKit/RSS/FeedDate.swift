import Foundation

/// The dates feeds carry: RFC 822 in RSS (`pubDate`), RFC 3339 in Atom and
/// Dublin Core (`published`, `dc:date`). Real feeds stretch both, so the
/// parsers accept the common variants and return nil for anything else.
enum FeedDate {
    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else { return nil }
        // RFC 3339 starts with a four-digit year; RFC 822 with a day name
        // or the day of the month.
        if trimmed.count >= 10, CharacterSet.decimalDigits.contains(first),
           trimmed.unicodeScalars.dropFirst(4).first == "-" {
            return iso8601(trimmed) ?? rfc822(trimmed)
        }
        return rfc822(trimmed) ?? iso8601(trimmed)
    }

    /// `2026-10-24T01:49:34Z`, `2026-10-24T01:49:34.123+01:00`,
    /// `2026-10-24 01:49`, `2026-10-24`.
    static func iso8601(_ string: String) -> Date? {
        var scanner = Scanner(Array(string.utf8))
        guard let year = scanner.int(digits: 4), scanner.skip("-"),
              let month = scanner.int(digits: 2), scanner.skip("-"),
              let day = scanner.int(digits: 2) else { return nil }
        var hour = 0, minute = 0, second = 0.0, offset = 0
        if scanner.skip("T") || scanner.skip("t") || scanner.skip(" ") {
            guard let h = scanner.int(digits: 2), scanner.skip(":"), let m = scanner.int(digits: 2) else { return nil }
            hour = h
            minute = m
            if scanner.skip(":") {
                guard let s = scanner.int(digits: 2) else { return nil }
                second = Double(s)
                if scanner.skip(".") || scanner.skip(",") {
                    let start = scanner.index
                    var fraction = 0.0, scale = 0.1
                    while let digit = scanner.digit() {
                        fraction += Double(digit) * scale
                        scale /= 10
                    }
                    guard scanner.index > start else { return nil }
                    second += fraction
                }
            }
            scanner.skipSpaces()
            if scanner.skip("Z") || scanner.skip("z") {
                offset = 0
            } else if let sign = scanner.sign() {
                guard let oh = scanner.int(digits: 2) else { return nil }
                _ = scanner.skip(":")
                let om = scanner.int(digits: 2) ?? 0
                offset = sign * (oh * 3600 + om * 60)
            }
        }
        scanner.skipSpaces()
        guard scanner.atEnd else { return nil }
        return date(year: year, month: month, day: day, hour: hour, minute: minute, second: second, offset: offset)
    }

    /// The instant an RFC 822 date names when its US standard-time zone
    /// (`EST`, `CST`, `MST`, `PST`) is read as that zone's daylight time,
    /// or nil unless it carries one on a date US daylight saving covers.
    /// Some feeds write "EST" all year for Eastern local time (ESPN);
    /// `ArticleMapper` uses this reading for the ones it knows.
    static func daylightReading(_ string: String) -> Date? {
        rfc822(string.trimmingCharacters(in: .whitespacesAndNewlines), readingStandardAsDaylight: true)
    }

    /// `Sat, 07 Sep 2002 00:00:01 GMT`, `7 Sep 02 00:00 +0100`,
    /// `Saturday, 07 September 2002 00:00:01 EST`.
    static func rfc822(_ string: String) -> Date? {
        rfc822(string, readingStandardAsDaylight: false)
    }

    private static func rfc822(_ string: String, readingStandardAsDaylight: Bool) -> Date? {
        let tokens = string
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" })
            .map(String.init)
        var day: Int?, month: Int?, year: Int?
        var hour = 0, minute = 0, second = 0.0, offset = 0
        var usStandardZone = false
        var sawTime = false
        for token in tokens {
            let lower = token.lowercased()
            if token.contains(":"), !sawTime {
                let parts = token.split(separator: ":")
                guard parts.count >= 2, parts.count <= 3,
                      let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
                hour = h
                minute = m
                if parts.count == 3 {
                    guard let s = Double(parts[2]) else { return nil }
                    second = s
                }
                sawTime = true
            } else if let number = Int(token), !token.hasPrefix("+"), !token.hasPrefix("-") {
                if day == nil, month == nil || year == nil, number >= 1, number <= 31, token.count <= 2 {
                    day = number
                } else if year == nil {
                    year = token.count <= 2 ? (number < 50 ? 2000 + number : 1900 + number) : number
                } else {
                    return nil
                }
            } else if month == nil, let m = months.firstIndex(where: { lower.hasPrefix($0) }) {
                month = m + 1
            } else if let sign = token.first.flatMap({ $0 == "+" ? 1 : $0 == "-" ? -1 : nil }) {
                let digits = token.dropFirst().filter { $0 != ":" }
                guard digits.count == 4, let value = Int(digits) else { return nil }
                offset = sign * ((value / 100) * 3600 + (value % 100) * 60)
            } else if let zone = zones[lower] {
                offset = zone * 3600
                usStandardZone = usStandardZones.contains(lower)
            } else if days.contains(where: { lower.hasPrefix($0) }) {
                continue
            } else if lower == "at" {
                continue
            } else {
                // An unknown zone name: treat as GMT rather than lose the date.
                guard sawTime, lower.allSatisfy(\.isLetter) else { return nil }
            }
        }
        guard let day, let month, let year else { return nil }
        if readingStandardAsDaylight {
            guard usStandardZone, (1900...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
                  observesDaylightTime(year: year, month: month, day: day, hour: hour) else { return nil }
            offset += 3600
        }
        return date(year: year, month: month, day: day, hour: hour, minute: minute, second: second, offset: offset)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private static let zones: [String: Int] = [
        "gmt": 0, "ut": 0, "utc": 0, "z": 0,
        "est": -5, "edt": -4, "cst": -6, "cdt": -5, "mst": -7, "mdt": -6, "pst": -8, "pdt": -7,
        "bst": 1, "cet": 1, "cest": 2, "jst": 9, "aest": 10,
    ]
    private static let usStandardZones: Set<String> = ["est", "cst", "mst", "pst"]

    /// Whether US daylight saving time is in force at a local civil time:
    /// from 2 a.m. on the second Sunday in March to 2 a.m. on the first
    /// Sunday in November (from 2007; before that, the first Sunday in
    /// April to the last Sunday in October).
    private static func observesDaylightTime(year: Int, month: Int, day: Int, hour: Int) -> Bool {
        let (startMonth, startDay, endMonth, endDay) = year >= 2007
            ? (3, nthSunday(2, month: 3, year: year), 11, nthSunday(1, month: 11, year: year))
            : (4, nthSunday(1, month: 4, year: year), 10, nthSunday(1, month: 11, year: year) + 24) // October has 31 days
        let now = (month, day, hour)
        return now >= (startMonth, startDay, 2) && now < (endMonth, endDay, 2)
    }

    /// The day of the month of the `n`th Sunday of a month.
    private static func nthSunday(_ n: Int, month: Int, year: Int) -> Int {
        // 1970-01-01 was a Thursday; weekday 0 is Sunday.
        let weekdayOfFirst = ((daysFromCivil(year: year, month: month, day: 1) % 7) + 11) % 7
        return 1 + (7 - weekdayOfFirst) % 7 + (n - 1) * 7
    }

    /// The instant a civil date and time at `offset` seconds from UTC
    /// names, without Calendar so parsing a large feed stays cheap.
    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Double, offset: Int) -> Date? {
        guard (1900...9999).contains(year), (1...12).contains(month), (1...daysIn(month, of: year)).contains(day),
              (0...23).contains(hour) || (hour == 24 && minute == 0 && second == 0),
              (0...59).contains(minute), second >= 0, second < 61 else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 - offset) + second
        return Date(timeIntervalSince1970: seconds)
    }
}

extension FeedDate {
    /// Days from 1970-01-01 (Howard Hinnant's days_from_civil).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func daysIn(_ month: Int, of year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

/// A cursor over ASCII bytes, for the date parsers.
private struct Scanner {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var atEnd: Bool { index == bytes.count }

    mutating func skip(_ character: Character) -> Bool {
        guard index < bytes.count, let ascii = character.asciiValue, bytes[index] == ascii else { return false }
        index += 1
        return true
    }

    mutating func skipSpaces() {
        while index < bytes.count, bytes[index] == 0x20 {
            index += 1
        }
    }

    mutating func digit() -> Int? {
        guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { return nil }
        defer { index += 1 }
        return Int(bytes[index] - 0x30)
    }

    mutating func int(digits count: Int) -> Int? {
        let start = index
        var value = 0
        for _ in 0..<count {
            guard let digit = digit() else {
                index = start
                return nil
            }
            value = value * 10 + digit
        }
        return value
    }

    mutating func sign() -> Int? {
        if skip("+") { return 1 }
        if skip("-") { return -1 }
        return nil
    }
}
