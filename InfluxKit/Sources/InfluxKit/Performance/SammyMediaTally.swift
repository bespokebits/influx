import Foundation
import Synchronization

/// What Sammy media grants did since the last field report (ADR 0034, ADR
/// 0039): how many grants were asked for, how many requests the server
/// answered with a 429, how many were held back after one, and how many
/// author pictures waited for their allowance, for author pictures and
/// attachments apart; and since ADR 0040 how many loads went straight to
/// the source, how many of those failed and fell back to a grant, and how
/// long images took to arrive each way, in coarse buckets. Every
/// `SammyMediaGrants` counts into `shared`. Nothing counted names an
/// account, feed, media ID or URL.
///
/// It counts in memory. Once a TestFlight install keeps it in a file
/// (`keep(in:build:)`), it is written there at most every `saveDelay`, so
/// counts from earlier runs of the same build reach the next report too.
public final class SammyMediaTally: Sendable {
    public static let shared = SammyMediaTally()

    public enum Event: Sendable {
        /// A grant asked for: sent to the server.
        case grants
        /// A grant request the server answered with a 429.
        case grantsRateLimited
        /// A byte request the server answered with a 429.
        case bytesRateLimited
        /// A request refused at once, sending nothing, while a 429 held it back.
        case heldBack
        /// A picture's grant not asked for, because its allowance was spent.
        case deferred
        /// Bytes read straight from the source's media servers: an image, or
        /// a video's first range.
        case direct
        /// A direct read that failed, read through a grant instead.
        case fallback
    }

    /// How an image's bytes came, for its time to image.
    public enum Path: Sendable {
        case direct, grant
    }

    /// How long a count waits before it is written, so a busy scroll writes
    /// the file once, not per image.
    static let saveDelay: Duration = .seconds(30)

    private struct Saved: Codable {
        var build: String
        var counts: PerformanceReport.SammyMedia
    }

    private struct State {
        var counts = PerformanceReport.SammyMedia()
        var file: URL?
        var build = ""
        var saveScheduled = false
    }

    private let state = Mutex(State())
    /// Held while writing, so an older snapshot never lands over a newer one.
    private let writing = Mutex(())

    public init() {}

    /// The counts so far.
    public var counts: PerformanceReport.SammyMedia { state.withLock { $0.counts } }

    func record(_ event: Event, _ kind: SammyMediaGrants.Kind) {
        let schedule = state.withLock { state -> Bool in
            state.counts.add(event, kind)
            guard state.file != nil, !state.saveScheduled else { return false }
            state.saveScheduled = true
            return true
        }
        guard schedule else { return }
        Task.detached(priority: .background) { [self] in
            try? await Task.sleep(for: Self.saveDelay)
            save()
        }
    }

    /// Counts how long an image took, from asking for its bytes to having
    /// them, in its bucket (`PerformanceReport.SammyMedia.TimeToImage`).
    func time(_ path: Path, _ duration: Duration) {
        let schedule = state.withLock { state -> Bool in
            state.counts.timeToImage.add(path, duration)
            guard state.file != nil, !state.saveScheduled else { return false }
            state.saveScheduled = true
            return true
        }
        guard schedule else { return }
        Task.detached(priority: .background) { [self] in
            try? await Task.sleep(for: Self.saveDelay)
            save()
        }
    }

    /// Keeps the counts in `file` from now on, adding what it holds for
    /// `build`. Counts it holds for another build are dropped, since a
    /// report never spans an update. Only the first call does anything.
    public func keep(in file: URL, build: String) {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        let first = state.withLock { state -> Bool in
            guard state.file == nil else { return false }
            if let saved, saved.build == build { state.counts.add(saved.counts) }
            state.file = file
            state.build = build
            return true
        }
        if first { save() }
    }

    /// The counts since the last call, or nil when nothing was counted,
    /// and starts again from zero.
    public func take() -> PerformanceReport.SammyMedia? {
        let counts = state.withLock { state in
            defer { state.counts = PerformanceReport.SammyMedia() }
            return state.counts
        }
        save()
        return counts.isEmpty ? nil : counts
    }

    /// Writes the counts to the kept file, if there is one.
    func save() {
        writing.withLock { _ in
            let taken = state.withLock { state -> (file: URL, saved: Saved)? in
                state.saveScheduled = false
                return state.file.map { ($0, Saved(build: state.build, counts: state.counts)) }
            }
            guard let (file, snapshot) = taken else { return }
            // Written beside the file and renamed over it, as the waiting
            // reports are (`PerformanceReporter`).
            let written = file.appendingPathExtension("new")
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: written)
                guard rename(written.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            } catch {
                try? FileManager.default.removeItem(at: written)
            }
        }
    }
}

extension PerformanceReport {
    /// What Sammy media grants did over a report's period (`SammyMediaTally`).
    public struct SammyMedia: Codable, Hashable, Sendable {
        public struct Counts: Codable, Hashable, Sendable {
            public var grants = 0
            public var grantsRateLimited = 0
            public var bytesRateLimited = 0
            public var heldBack = 0
            public var deferred = 0
            /// Since ADR 0040: reads straight from the source.
            public var direct = 0
            /// Since ADR 0040: direct reads that fell back to a grant.
            public var fallbacks = 0

            public init(grants: Int = 0, grantsRateLimited: Int = 0, bytesRateLimited: Int = 0, heldBack: Int = 0, deferred: Int = 0,
                        direct: Int = 0, fallbacks: Int = 0) {
                self.grants = grants
                self.grantsRateLimited = grantsRateLimited
                self.bytesRateLimited = bytesRateLimited
                self.heldBack = heldBack
                self.deferred = deferred
                self.direct = direct
                self.fallbacks = fallbacks
            }

            private enum CodingKeys: String, CodingKey {
                case grants, grantsRateLimited, bytesRateLimited, heldBack, deferred, direct, fallbacks
            }

            /// Counts kept or queued by a build before ADR 0040 have no
            /// direct counts: they read as none.
            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.init(grants: try container.decode(Int.self, forKey: .grants),
                          grantsRateLimited: try container.decode(Int.self, forKey: .grantsRateLimited),
                          bytesRateLimited: try container.decode(Int.self, forKey: .bytesRateLimited),
                          heldBack: try container.decode(Int.self, forKey: .heldBack),
                          deferred: try container.decode(Int.self, forKey: .deferred),
                          direct: try container.decodeIfPresent(Int.self, forKey: .direct) ?? 0,
                          fallbacks: try container.decodeIfPresent(Int.self, forKey: .fallbacks) ?? 0)
            }

            var isEmpty: Bool { self == Counts() }

            mutating func add(_ event: SammyMediaTally.Event) {
                switch event {
                case .grants: grants = Self.sum(grants, 1)
                case .grantsRateLimited: grantsRateLimited = Self.sum(grantsRateLimited, 1)
                case .bytesRateLimited: bytesRateLimited = Self.sum(bytesRateLimited, 1)
                case .heldBack: heldBack = Self.sum(heldBack, 1)
                case .deferred: deferred = Self.sum(deferred, 1)
                case .direct: direct = Self.sum(direct, 1)
                case .fallback: fallbacks = Self.sum(fallbacks, 1)
                }
            }

            mutating func add(_ other: Counts) {
                grants = Self.sum(grants, other.grants)
                grantsRateLimited = Self.sum(grantsRateLimited, other.grantsRateLimited)
                bytesRateLimited = Self.sum(bytesRateLimited, other.bytesRateLimited)
                heldBack = Self.sum(heldBack, other.heldBack)
                deferred = Self.sum(deferred, other.deferred)
                direct = Self.sum(direct, other.direct)
                fallbacks = Self.sum(fallbacks, other.fallbacks)
            }

            /// Within the Worker's bound for a count.
            static func sum(_ a: Int, _ b: Int) -> Int {
                min(max(a, 0) + max(b, 0), PerformanceReport.maxMediaCount)
            }
        }

        /// How long Sammy images took to arrive, from asking for their bytes
        /// to having them (ADR 0040): a count per bucket, for images read
        /// straight from the source and through a grant apart. The buckets'
        /// upper bounds are `bounds`, and one more counts the rest.
        public struct TimeToImage: Codable, Hashable, Sendable {
            /// In milliseconds; the Worker's `TIME_TO_IMAGE_BOUNDS_MS`.
            public static let bounds = [100, 250, 500, 1000, 2500, 5000]
            static var buckets: Int { bounds.count + 1 }

            public var direct = Array(repeating: 0, count: TimeToImage.buckets)
            public var grant = Array(repeating: 0, count: TimeToImage.buckets)

            public init(direct: [Int]? = nil, grant: [Int]? = nil) {
                if let direct, direct.count == Self.buckets { self.direct = direct }
                if let grant, grant.count == Self.buckets { self.grant = grant }
            }

            var isEmpty: Bool { self == TimeToImage() }

            /// The bucket `duration` falls in.
            static func bucket(_ duration: Duration) -> Int {
                let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
                return bounds.firstIndex { milliseconds <= Double($0) } ?? bounds.count
            }

            mutating func add(_ path: SammyMediaTally.Path, _ duration: Duration) {
                let bucket = Self.bucket(duration)
                switch path {
                case .direct: direct[bucket] = Counts.sum(direct[bucket], 1)
                case .grant: grant[bucket] = Counts.sum(grant[bucket], 1)
                }
            }

            mutating func add(_ other: TimeToImage) {
                for bucket in 0..<Self.buckets {
                    direct[bucket] = Counts.sum(direct[bucket], other.direct[bucket])
                    grant[bucket] = Counts.sum(grant[bucket], other.grant[bucket])
                }
            }

            private enum CodingKeys: String, CodingKey { case direct, grant }

            /// Holds exactly one count a bucket, or decodes as none.
            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.init(direct: try container.decode([Int].self, forKey: .direct), grant: try container.decode([Int].self, forKey: .grant))
            }
        }

        /// Authors' and reposters' pictures.
        public var avatar = Counts()
        /// Everything else a post shows: attachments, previews, quote and card pictures.
        public var attachment = Counts()
        /// Since ADR 0040.
        public var timeToImage = TimeToImage()

        public init(avatar: Counts = Counts(), attachment: Counts = Counts(), timeToImage: TimeToImage = TimeToImage()) {
            self.avatar = avatar
            self.attachment = attachment
            self.timeToImage = timeToImage
        }

        private enum CodingKeys: String, CodingKey { case avatar, attachment, timeToImage }

        /// What a build before ADR 0040 kept or queued has no time to image.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(avatar: try container.decode(Counts.self, forKey: .avatar),
                      attachment: try container.decode(Counts.self, forKey: .attachment),
                      timeToImage: try container.decodeIfPresent(TimeToImage.self, forKey: .timeToImage) ?? TimeToImage())
        }

        var isEmpty: Bool { avatar.isEmpty && attachment.isEmpty && timeToImage.isEmpty }

        mutating func add(_ event: SammyMediaTally.Event, _ kind: SammyMediaGrants.Kind) {
            switch kind {
            case .avatar: avatar.add(event)
            case .attachment: attachment.add(event)
            }
        }

        mutating func add(_ other: SammyMedia) {
            avatar.add(other.avatar)
            attachment.add(other.attachment)
            timeToImage.add(other.timeToImage)
        }
    }
}
