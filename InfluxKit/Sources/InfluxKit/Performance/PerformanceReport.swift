import Foundation

/// One MetricKit payload's figures, as a TestFlight install reports them to
/// the OAuth Worker's `/perf/report` (ADR 0034): the build, OS and hardware
/// it ran on, its scroll hitch ratio, and its launch and resume times as
/// histograms. It names nothing about the reader.
///
/// It encodes to exactly the Worker's schema, which refuses any other
/// field: `scrollHitchMsPerS` as `null` when nothing was measured, and
/// `resume` and `sammyMedia` left out when there is none.
public struct PerformanceReport: Codable, Hashable, Sendable {
    public enum Platform: String, Codable, Hashable, Sendable {
        case ios
        case mac
    }

    /// `count` launches took from `startMs` up to `endMs`.
    public struct Bucket: Codable, Hashable, Sendable {
        public var startMs: Int
        public var endMs: Int
        public var count: Int

        public init(startMs: Int, endMs: Int, count: Int) {
            self.startMs = startMs
            self.endMs = endMs
            self.count = count
        }
    }

    /// The Worker's bounds (`server/oauth-worker/src/perf.ts`).
    public static let maxBuckets = 24
    public static let maxBucketMs = 600_000
    public static let maxBucketCount = 1_000_000
    public static let maxHitchMsPerS = 1000.0
    public static let maxMediaCount = 1_000_000

    /// Made for this report alone, and kept with it while it waits, so the
    /// Worker stores a report sent again once. It names no install.
    public var id: UUID
    public var platform: Platform
    /// `CFBundleVersion`, dotted digits.
    public var build: String
    /// The OS version, dotted digits.
    public var os: String
    /// The hardware model, such as `iPhone16,2`.
    public var device: String
    public var periodStart: Date
    public var periodEnd: Date
    /// Scroll hitch time per second of scrolling; nil when none was measured.
    public var scrollHitchMsPerS: Double?
    /// Time to first draw.
    public var launch: [Bucket]
    /// Time to resume, when the payload had it.
    public var resume: [Bucket]?
    /// What Sammy media grants did since the last report, when they did
    /// anything (ADR 0039).
    public var sammyMedia: SammyMedia?

    public init(
        id: UUID = UUID(), platform: Platform, build: String, os: String, device: String, periodStart: Date, periodEnd: Date,
        scrollHitchMsPerS: Double?, launch: [Bucket], resume: [Bucket]?, sammyMedia: SammyMedia? = nil
    ) {
        self.id = id
        self.platform = platform
        self.build = build
        self.os = os
        self.device = device
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.scrollHitchMsPerS = scrollHitchMsPerS
        self.launch = launch
        self.resume = resume
        self.sammyMedia = sammyMedia
    }

    private enum CodingKeys: String, CodingKey {
        case id, platform, build, os, device, periodStart, periodEnd, scrollHitchMsPerS, launch, resume, sammyMedia
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        platform = try container.decode(Platform.self, forKey: .platform)
        build = try container.decode(String.self, forKey: .build)
        os = try container.decode(String.self, forKey: .os)
        device = try container.decode(String.self, forKey: .device)
        periodStart = try Date(container.decode(String.self, forKey: .periodStart), strategy: .iso8601)
        periodEnd = try Date(container.decode(String.self, forKey: .periodEnd), strategy: .iso8601)
        scrollHitchMsPerS = try container.decodeIfPresent(Double.self, forKey: .scrollHitchMsPerS)
        launch = try container.decode([Bucket].self, forKey: .launch)
        resume = try container.decodeIfPresent([Bucket].self, forKey: .resume)
        sammyMedia = try container.decodeIfPresent(SammyMedia.self, forKey: .sammyMedia)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Upper case, as the Worker wants it.
        try container.encode(id.uuidString, forKey: .id)
        try container.encode(platform, forKey: .platform)
        try container.encode(build, forKey: .build)
        try container.encode(os, forKey: .os)
        try container.encode(device, forKey: .device)
        // RFC 3339, whatever the encoder's date strategy.
        try container.encode(periodStart.formatted(.iso8601), forKey: .periodStart)
        try container.encode(periodEnd.formatted(.iso8601), forKey: .periodEnd)
        // The Worker wants the field present, null when nothing was measured.
        if let scrollHitchMsPerS {
            try container.encode(scrollHitchMsPerS, forKey: .scrollHitchMsPerS)
        } else {
            try container.encodeNil(forKey: .scrollHitchMsPerS)
        }
        try container.encode(launch, forKey: .launch)
        try container.encodeIfPresent(resume, forKey: .resume)
        try container.encodeIfPresent(sammyMedia, forKey: .sammyMedia)
    }
}

// MARK: From MetricKit

extension PerformanceReport {
    /// A payload's figures as MetricKit gives them, before they are fitted
    /// to the Worker's schema. The app's MetricKit framework sends this as
    /// JSON (InfluxMetrics links MetricKit; InfluxKit can't, being built on
    /// Linux too).
    public struct Measured: Codable, Hashable, Sendable {
        /// A ratio and its unit's symbol, as MetricKit's `Measurement` has them.
        public struct Ratio: Codable, Hashable, Sendable {
            public var value: Double
            public var unit: String

            public init(value: Double, unit: String) {
                self.value = value
                self.unit = unit
            }
        }

        /// A histogram bucket in milliseconds.
        public struct Bucket: Codable, Hashable, Sendable {
            public var startMs: Double
            public var endMs: Double
            public var count: Int

            public init(startMs: Double, endMs: Double, count: Int) {
                self.startMs = startMs
                self.endMs = endMs
                self.count = count
            }
        }

        public var platform: Platform
        public var build: String
        /// As MetricKit words it, such as "iPhone OS 27.2 (24C101)".
        public var os: String
        public var device: String
        /// Seconds since 1970.
        public var periodStart: Double
        public var periodEnd: Double
        public var scrollHitch: Ratio?
        public var launch: [Bucket]
        public var resume: [Bucket]?

        public init(
            platform: Platform, build: String, os: String, device: String, periodStart: Double, periodEnd: Double,
            scrollHitch: Ratio?, launch: [Bucket], resume: [Bucket]?
        ) {
            self.platform = platform
            self.build = build
            self.os = os
            self.device = device
            self.periodStart = periodStart
            self.periodEnd = periodEnd
            self.scrollHitch = scrollHitch
            self.launch = launch
            self.resume = resume
        }
    }

    /// The report the Worker takes from `measured`, or nil when its build,
    /// OS or device can't be put in the Worker's terms. Histograms are
    /// rounded out to whole milliseconds, kept within the Worker's bounds
    /// and, past 24 buckets, merged, closest neighbours first, until they fit.
    public init?(measured: Measured) {
        guard let build = Self.dotted(measured.build), build == measured.build,
              let os = Self.dotted(measured.os) else { return nil }
        let device = String(measured.device.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ",") }.prefix(24))
        guard !device.isEmpty, measured.periodStart.isFinite, measured.periodEnd.isFinite,
              measured.periodStart <= measured.periodEnd else { return nil }
        self.init(
            platform: measured.platform, build: build, os: os, device: device,
            periodStart: Date(timeIntervalSince1970: measured.periodStart.rounded(.down)),
            periodEnd: Date(timeIntervalSince1970: measured.periodEnd.rounded(.up)),
            scrollHitchMsPerS: measured.scrollHitch.flatMap(Self.msPerSecond),
            launch: Self.buckets(measured.launch),
            resume: measured.resume.map(Self.buckets)
        )
    }

    /// The first run of dotted digits in `text` ("27.2" in "iPhone OS 27.2
    /// (24C101)"), if it has one of at most 20 characters.
    static func dotted(_ text: String) -> String? {
        guard let start = text.firstIndex(where: \.isASCIIDigit) else { return nil }
        var run = String(text[start...].prefix { $0.isASCIIDigit || $0 == "." })
        while run.hasSuffix(".") { run.removeLast() }
        // "27..2" isn't a version.
        guard !run.contains(".."), run.count <= 20 else { return nil }
        return run
    }

    /// A hitch ratio in ms per second. MetricKit's unit is "ms per s"; a
    /// ratio given without milliseconds is taken as a plain fraction.
    static func msPerSecond(_ ratio: Measured.Ratio) -> Double? {
        guard ratio.value.isFinite else { return nil }
        let value = ratio.unit.contains("ms") ? ratio.value : ratio.value * 1000
        return min(max(value, 0), maxHitchMsPerS)
    }

    /// Whole-millisecond buckets within the Worker's bounds, empty ones left
    /// out, in order, at most `maxBuckets`.
    static func buckets(_ measured: [Measured.Bucket]) -> [Bucket] {
        var buckets = measured.compactMap { bucket -> Bucket? in
            guard bucket.count > 0, bucket.startMs.isFinite, bucket.endMs.isFinite else { return nil }
            let start = Int(max(bucket.startMs, 0).rounded(.down))
            guard start < maxBucketMs else { return nil }
            let end = min(max(Int(min(bucket.endMs, Double(maxBucketMs)).rounded(.up)), start + 1), maxBucketMs)
            return Bucket(startMs: start, endMs: end, count: min(bucket.count, maxBucketCount))
        }
        .sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }
        // Past the limit, the neighbours whose merged span is narrowest
        // become one, again and again: the Worker spreads a bucket's
        // launches across all of it, so a gap between far-apart buckets is
        // kept unless nothing narrower is left.
        while buckets.count > maxBuckets {
            let index = buckets.indices.dropLast().min { left, right in
                buckets[left + 1].endMs - buckets[left].startMs < buckets[right + 1].endMs - buckets[right].startMs
            }!
            let first = buckets[index], second = buckets[index + 1]
            buckets[index] = Bucket(
                startMs: first.startMs, endMs: max(first.endMs, second.endMs),
                count: min(first.count + second.count, maxBucketCount)
            )
            buckets.remove(at: index + 1)
        }
        return buckets
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
