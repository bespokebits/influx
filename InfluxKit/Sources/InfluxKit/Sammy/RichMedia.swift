import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a rich post's attachment is, as the store keeps it (ADR 0031):
/// `sammy-media:<account>/<feed>/<media>`, and `?variant=preview` after it
/// for a video's or GIF's still. It names the account whose credential may
/// ask for the bytes, the feed the post was served in and the source's own
/// media ID. It is never a URL: a grant's URL expires within the hour, so
/// one is asked for whenever bytes are needed (`SammyMediaGrants`).
///
/// An attachment of a post read in a thread also names the thread,
/// `?thread=<ref>` (before any `&variant=preview`), whose grant it is asked
/// for with: the server grants a thread's media by the thread, so a
/// context post older than the feed's window keeps its pictures. Thread
/// posts are never stored, so neither is such a reference.
public struct SammyMediaReference: Sendable, Hashable {
    public static let scheme = "sammy-media:"

    /// `<subject>@<host>`, as `SammySession.accountID` gives it.
    public let accountID: String
    public let feedID: String
    /// The source's own ID for the attachment, `[A-Za-z0-9_-]{1,128}`.
    public let mediaID: String
    /// The still preview of a video or GIF, not the attachment itself.
    public let preview: Bool
    /// The thread the attachment was read in, `[A-Za-z0-9_-]{1,256}`; nil
    /// for one on a feed's page.
    public let thread: String?

    init?(accountID: String, feedID: String, mediaID: String, preview: Bool = false, thread: String? = nil) {
        guard !accountID.isEmpty, SammyFeedList.isSafeID(feedID), Self.isMediaID(mediaID),
              thread.map(RichFeedPage.isThreadRef) ?? true else { return nil }
        self.accountID = accountID
        self.feedID = feedID
        self.mediaID = mediaID
        self.preview = preview
        self.thread = thread
    }

    /// The reference `string` spells, exactly as `string` would give it;
    /// nil for anything else, a URL included.
    public init?(_ string: String) {
        guard string.hasPrefix(Self.scheme) else { return nil }
        var rest = Substring(string.dropFirst(Self.scheme.count))
        var preview = false
        var thread: String?
        if let query = rest.firstIndex(of: "?") {
            for part in rest[rest.index(after: query)...].split(separator: "&", omittingEmptySubsequences: false) {
                if part == "variant=preview", !preview {
                    preview = true
                } else if part.hasPrefix("thread="), thread == nil, !preview {
                    thread = String(part.dropFirst("thread=".count))
                } else {
                    return nil
                }
            }
            rest = rest[..<query]
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, let account = String(parts[0]).removingPercentEncoding,
              let reference = SammyMediaReference(accountID: account, feedID: String(parts[1]), mediaID: String(parts[2]),
                                                  preview: preview, thread: thread),
              reference.string == string else { return nil }
        self = reference
    }

    public var string: String {
        let account = accountID.addingPercentEncoding(withAllowedCharacters: Self.accountCharacters) ?? ""
        let query = [thread.map { "thread=\($0)" }, preview ? "variant=preview" : nil].compactMap { $0 }
        return "\(Self.scheme)\(account)/\(feedID)/\(mediaID)\(query.isEmpty ? "" : "?" + query.joined(separator: "&"))"
    }

    /// The attachment itself, for a preview's reference.
    public var original: SammyMediaReference {
        SammyMediaReference(accountID: accountID, feedID: feedID, mediaID: mediaID, thread: thread)!
    }

    /// Whether `value` is a media ID as the contract allows one:
    /// `[A-Za-z0-9_-]`, 1 to `longest` bytes.
    static func isMediaID(_ value: String, upTo longest: Int = 128) -> Bool {
        let bytes = Array(value.utf8)
        return (1...longest).contains(bytes.count) && bytes.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// An account ID keeps its letters, digits, `-._~` and `@`; anything
    /// else (a port's `:`, a `/`) is percent-encoded, so it can't run into
    /// the feed's part.
    private static let accountCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@")
}

/// The bytes of one Sammy account's rich post media (ADR 0031): asks the
/// account's own server for a short-lived grant with the account's
/// credential, then reads the grant's URL with no credential at all, over
/// a connection of its own (`HTTPClient.send(_:upTo:at:)`) that follows no
/// redirect and stops reading at the caller's limit, so an oversized body
/// never sits in memory whole.
///
/// - A grant is asked for only with this account's credential, only from
///   its server, through `SammyAccount.send` like every feed read. A grant
///   whose URL is not https on that same origin, under the contract's
///   media path, is refused.
/// - A grant is kept until `renewalMargin` before it expires, so the
///   attachments of one post share one request each, and a later load asks
///   again. A 404 or 410 from the grant's URL means it has gone: a new
///   grant is asked for and the read tried once more.
/// - At most `streams` requests are out at once, the server's own limit for
///   an account. A 429 holds requests back until its `Retry-After`
///   (`firstBackoff` when it gives none, never past `longestBackoff`); a
///   request held back fails at once with `.rateLimited`, and the caller
///   tries it later, as a failed image is.
/// - An author's picture (`Kind.avatar`) gives way to attachments (ADR
///   0039): it takes at most `avatarStreams` of the slots and waits behind
///   any attachment, a 429 answered to it holds back only other pictures,
///   and its grants come out of an allowance (`Allowance`), so pictures
///   never spend much of the read limit that grants share with feed reads.
///   A 429 answered to an attachment holds back both.
/// - A grant whose callers have all stopped waiting before it is sent is
///   never sent. Once sent, its answer is kept.
/// - A body shorter than its length, or a range that isn't the one asked
///   for, is a failed read. Nothing is kept on disk.
/// - Where the server says a media ID's source serves it publicly (ADR
///   0040), its bytes are read from the source instead, at the size drawn,
///   through `direct`: https to public addresses only, checked at every
///   redirect, with byte limits, and no cookie, credential or referrer. The
///   answers come for up to 50 IDs of a feed in one request
///   (`SammyMediaSources`), asked for as rows are about to show (`warm`),
///   and are kept until they expire. Any failure of a direct load falls back
///   to the grant for that media ID, which it then always uses; a server
///   that doesn't offer the batch is read exactly as before, and isn't asked
///   again for an hour.
/// - What happens is counted in `tally`, for the field reports (ADR 0034).
public actor SammyMediaGrants {
    /// What the bytes are for.
    public enum Kind: Sendable, Hashable {
        /// An attachment, its preview, or a quote's or link card's picture:
        /// part of what the post shows.
        case attachment
        /// An author's or reposter's picture, which a monogram stands in for.
        case avatar
    }

    /// The grants an author's picture may spend: up to `burst` at once,
    /// coming back at `perHour`, a fifth of the server's 600 an hour that
    /// feed reads and grants share. A picture refused by it fails at once
    /// with `.rateLimited`, sending nothing, and is tried again as a
    /// failed image is.
    struct Allowance {
        static let burst = 60.0
        static let perHour = 120.0

        private var tokens = Self.burst
        private var at: Date?

        /// Takes one grant, and returns nil; or, when none is left,
        /// returns when the next one comes.
        mutating func take(now: Date) -> Date? {
            if let at { tokens = min(Self.burst, tokens + max(0, now.timeIntervalSince(at)) * Self.perHour / 3600) }
            at = now
            guard tokens >= 1 else { return now.addingTimeInterval((1 - tokens) * 3600 / Self.perHour) }
            tokens -= 1
            return nil
        }
    }

    /// What the server gave: the URL to read and when it stops working.
    public struct Grant: Sendable, Hashable {
        public var url: URL
        public var expiresAt: Date
    }

    /// How long before it expires a grant is no longer used.
    static let renewalMargin: TimeInterval = 30
    /// Requests out at once: the server's default for an account.
    static let streams = 4
    /// Of those, the most an author's picture may hold, so attachments
    /// always have the rest.
    static let avatarStreams = 2
    static let firstBackoff: TimeInterval = 5
    static let longestBackoff: TimeInterval = 300
    /// Grants remembered; the expired ones go first when it fills.
    static let cacheLimit = 1_000
    /// Where the contract puts a grant's URL on the server.
    static let grantPath = "/api/v1/rich-media/"
    /// How long a direct load may take before its grant is tried instead.
    static let directTimeout: Duration = .seconds(10)
    /// How long the server's "use a grant" or "gone" for an ID is kept.
    static let answerLife: TimeInterval = 15 * 60
    /// How long a server that doesn't offer direct sources isn't asked again.
    static let unsupportedWait: TimeInterval = 60 * 60
    /// How long a batch of IDs waits for more before it is sent, so the rows
    /// about to show ask together.
    static let batchDelay: Duration = .milliseconds(30)
    /// How long the server has to answer a batch before its IDs read through
    /// their grants: well inside a caller's deadline, so the fallback still
    /// has time, and its slot is given back.
    static let sourcesTimeout: Duration = .seconds(5)

    public nonisolated let accountID: String
    private let account: SammyAccount
    private let http: any HTTPClient
    /// Where the server's name points. Not held to public addresses: the
    /// reader chose this server and signed in to it.
    private let addresses: AddressLookup
    private let now: @Sendable () -> Date
    private let tally: SammyMediaTally

    /// What a grant is for: an attachment of a feed, and the thread it is
    /// granted by when it was read in one.
    private struct Key: Hashable {
        var feedID: String
        var mediaID: String
        var thread: String?

        init(_ reference: SammyMediaReference) {
            feedID = reference.feedID
            mediaID = reference.mediaID
            thread = reference.thread
        }
    }

    /// A grant being asked for, and how many callers wait for it; later
    /// callers for the same attachment join it.
    /// An ask: for one grant, by one kind of caller.
    private struct AskKey: Hashable {
        var key: Key
        var kind: Kind
    }

    private struct Asking {
        var id: Int
        var task: Task<Grant, any Error>
        var callers: Int
        /// Sent to the server: it stays here until its answer, whoever waits.
        var sent = false
    }

    private var grants: [Key: Grant] = [:]
    private var asking: [AskKey: Asking] = [:]
    private var nextAsk = 0
    /// Until when a 429 holds every request back.
    private var allHeldUntil: Date?
    /// Until when a 429 answered to a picture holds pictures back.
    private var avatarsHeldUntil: Date?
    private var allowance = Allowance()
    private var inUse = 0
    private var avatarsInUse = 0
    private var waitingAttachments: [CheckedContinuation<Void, Never>] = []
    private var waitingAvatars: [CheckedContinuation<Void, Never>] = []

    /// Reads a source's own media servers (ADR 0040).
    private let direct: MediaResolver
    /// Whether to ask the server for direct sources at all; off only in
    /// tests of the grants themselves.
    private let directSources: Bool
    private let sourcesTimeout: Duration
    /// The IDs of one feed (and thread) asked for together.
    private struct BatchKey: Hashable {
        var feedID: String
        var thread: String?
    }

    private struct KeptAnswer {
        var answer: SammyDirectAnswer
        var until: Date
    }

    /// IDs waiting to be asked for, and who waits for each.
    private struct Batch {
        var ids: [String] = []
        var waiters: [String: [(id: Int, continuation: CheckedContinuation<SammyDirectAnswer?, Never>)]] = [:]
    }

    /// What a direct read is of: the attachment, or its still.
    private struct DirectKey: Hashable {
        var key: Key
        var preview: Bool
    }

    private var answers: [Key: KeptAnswer] = [:]
    private var batches: [BatchKey: Batch] = [:]
    /// Batches sent and not yet answered, by each ID they ask about, so a
    /// caller for one joins it rather than asking again.
    private var inFlight: [Key: Task<[String: SammyDirectAnswer]?, Never>] = [:]
    private var nextWaiter = 0
    /// Until when the server is taken not to offer direct sources.
    private var sourcesUnsupportedUntil: Date?
    /// Media whose direct load failed: read through grants from now on.
    private var directFailed: Set<DirectKey> = []
    /// Videos read from a direct URL: every later range of the same
    /// playback reads the same file.
    private var playing: [Key: URL] = [:]

    /// `direct` reads the sources' own media servers; by default over
    /// `http`, held to public addresses at every hop.
    init(account: SammyAccount, http: any HTTPClient, addresses: AddressLookup = .system,
         now: @escaping @Sendable () -> Date = { Date() }, tally: SammyMediaTally = .shared, direct: MediaResolver? = nil,
         directSources: Bool = true, sourcesTimeout: Duration = SammyMediaGrants.sourcesTimeout) {
        accountID = account.accountID
        self.account = account
        self.http = http
        self.addresses = addresses
        self.now = now
        self.tally = tally
        self.direct = direct ?? MediaResolver(client: http)
        self.directSources = directSources
        self.sourcesTimeout = sourcesTimeout
    }

    /// The whole of `reference`'s bytes, at most `limit` of them. Throws a
    /// `ConnectorError`: `.notFound` for an attachment that is gone,
    /// `.unauthorized` when the account's credential was refused,
    /// `.rateLimited` while held back (or, for a picture, while its
    /// allowance is spent), `.offline` after `timeout`.
    ///
    /// `pixels` is the longest side it is drawn at: where its source serves
    /// it directly, the smallest size at least that large is read (the
    /// largest when nil), and a failed direct read falls back to the grant.
    public func data(for reference: SammyMediaReference, upTo limit: Int, timeout: Duration,
                     kind: Kind = .attachment, pixels: Int? = nil) async throws -> Data {
        guard reference.accountID == accountID else { throw ConnectorError.notFound }
        let started = ContinuousClock.now
        let answer = await withDeadline(timeout) { () async -> Result<(Data, SammyMediaTally.Path), ConnectorError>? in
            switch await self.directImage(reference, pixels: pixels, limit: limit, kind: kind) {
            case .loaded(let data): return .success((data, .direct))
            case .gone: return .failure(.notFound)
            case .cancelled: return .failure(.offline)
            case .unavailable: break
            }
            do {
                return .success((try await self.read(reference, range: nil, limit: limit, kind: kind).data, .grant))
            } catch let error as ConnectorError {
                return .failure(error)
            } catch {
                return .failure(.offline)
            }
        }
        guard let answer else { throw ConnectorError.offline }
        let (data, path) = try answer.get()
        tally.time(path, ContinuousClock.now - started)
        return data
    }

    /// `range` of `reference`'s bytes (all of them when nil), at most
    /// `limit`, for a player reading a video in pieces. Throws as `data`.
    /// A video its source serves directly is read from there, every range of
    /// one playback from the same file; until its first range has come,
    /// a failure falls back to the grant.
    public func fetch(_ reference: SammyMediaReference, bytes range: ClosedRange<Int>?, upTo limit: Int,
                      timeout: Duration, kind: Kind = .attachment) async throws -> RangedResponse {
        // Another account's attachment is never asked for with this one's
        // credential.
        guard reference.accountID == accountID else { throw ConnectorError.notFound }
        if let range, range.lowerBound < 0 { throw ConnectorError.badResponse("a negative range") }
        let answer = await withDeadline(timeout) { () async -> Result<RangedResponse, ConnectorError>? in
            if !reference.preview {
                switch await self.directVideo(reference, range: range, limit: limit, timeout: timeout, kind: kind) {
                case .loaded(let response): return .success(response)
                case .gone: return .failure(.notFound)
                case .failedPlaying, .cancelled: return .failure(.offline)
                case .unavailable: break
                }
            }
            do {
                return .success(try await self.read(reference, range: range, limit: limit, kind: kind))
            } catch let error as ConnectorError {
                return .failure(error)
            } catch {
                return .failure(.offline)
            }
        }
        guard let answer else { throw ConnectorError.offline }
        return try answer.get()
    }

    /// Asks the server, with the other IDs about to show, where
    /// `reference` may be read directly, so the answer is ready when its
    /// bytes are wanted. Sends nothing for an answer kept, or while the
    /// server is taken not to offer direct sources.
    public nonisolated func warm(_ reference: SammyMediaReference) {
        guard reference.accountID == accountID else { return }
        Task { _ = await self.answer(for: Key(reference)) }
    }

    // MARK: Direct sources (ADR 0040)

    private enum DirectImage {
        case loaded(Data)
        /// The server says it is gone; a grant would be a 404.
        case gone
        /// The caller stopped waiting (its row scrolled away): not the
        /// source's failure, so nothing falls back and nothing is counted.
        case cancelled
        /// Read it through the grant.
        case unavailable
    }

    private enum DirectVideo {
        case loaded(RangedResponse)
        case gone
        /// A later range of a video playing from its source failed: it
        /// can't switch to the grant's bytes mid-playback.
        case failedPlaying
        case cancelled
        case unavailable
    }

    private func directImage(_ reference: SammyMediaReference, pixels: Int?, limit: Int, kind: Kind) async -> DirectImage {
        let key = Key(reference), failure = DirectKey(key: key, preview: reference.preview)
        guard !directFailed.contains(failure), let answer = await self.answer(for: key) else { return .unavailable }
        switch answer {
        case .gone: return .gone
        case .grant: return .unavailable
        case .direct(let source):
            guard let image = source.image(forPixels: pixels ?? .max, preview: reference.preview) else { return .unavailable }
            let response = await direct.response(image.url, headers: ["Accept": "image/*"], upTo: limit, timeout: Self.directTimeout)
            if let (data, http) = response, http.statusCode == 200, Self.isType(http, "image/"),
               let checked = try? Self.checked(data, http, range: nil, limit: limit) {
                tally.record(.direct, kind)
                return .loaded(checked.data)
            }
            if Task.isCancelled { return .cancelled }
            directFailed.insert(failure)
            tally.record(.fallback, kind)
            return .unavailable
        }
    }

    private func directVideo(_ reference: SammyMediaReference, range: ClosedRange<Int>?, limit: Int, timeout: Duration,
                             kind: Kind) async -> DirectVideo {
        let key = Key(reference), failure = DirectKey(key: key, preview: false)
        // A later range of a playback that started directly: the same file,
        // while the server still offers it.
        if let url = playing[key], let range, range.lowerBound > 0 {
            guard case .direct(let source)? = await self.answer(for: key), source.videos.contains(where: { $0.url == url }),
                  let response = await rangeOf(url, range: range, limit: limit, timeout: timeout) else {
                return Task.isCancelled ? .cancelled : .failedPlaying
            }
            return .loaded(response)
        }
        playing[key] = nil
        guard !directFailed.contains(failure), let answer = await self.answer(for: key) else { return .unavailable }
        switch answer {
        case .gone: return .gone
        case .grant: return .unavailable
        case .direct(let source):
            guard let video = source.video else { return .unavailable }
            if let response = await rangeOf(video.url, range: range, limit: limit, timeout: timeout) {
                playing[key] = video.url
                tally.record(.direct, kind)
                return .loaded(response)
            }
            if Task.isCancelled { return .cancelled }
            directFailed.insert(failure)
            tally.record(.fallback, kind)
            return .unavailable
        }
    }

    /// `range` of the MP4 at `url`, read from its source: a 206 for exactly
    /// the range asked for (or a 200 when none was), of a video type.
    private func rangeOf(_ url: URL, range: ClosedRange<Int>?, limit: Int, timeout: Duration) async -> RangedResponse? {
        var headers = ["Accept": "video/mp4,video/*;q=0.9"]
        if let range { headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)" }
        guard let (data, http) = await direct.response(url, headers: headers, upTo: limit, timeout: min(timeout, Self.directTimeout)),
              http.statusCode == (range == nil ? 200 : 206), Self.isType(http, "video/") else { return nil }
        return try? Self.checked(data, http, range: range, limit: limit)
    }

    /// Whether the response's content type starts with `prefix`.
    private static func isType(_ response: HTTPURLResponse, _ prefix: String) -> Bool {
        response.value(forHTTPHeaderField: "Content-Type")?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(prefix) == true
    }

    /// The server's answer for `key`: kept, else asked for with the other
    /// IDs of its feed (and thread) waiting now. Nil when the server
    /// couldn't say, doesn't offer direct sources, or the caller stopped
    /// waiting: the grant is used.
    private func answer(for key: Key) async -> SammyDirectAnswer? {
        guard directSources else { return nil }
        let current = now()
        if let until = sourcesUnsupportedUntil, current < until { return nil }
        if let kept = answers[key], current < kept.until.addingTimeInterval(-Self.renewalMargin) { return kept.answer }
        if let asked = inFlight[key] { return await asked.value?[key.mediaID] }
        let batchKey = BatchKey(feedID: key.feedID, thread: key.thread)
        nextWaiter += 1
        let waiter = nextWaiter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SammyDirectAnswer?, Never>) in
                var batch = batches[batchKey] ?? Batch()
                let first = batch.ids.isEmpty
                if !batch.ids.contains(key.mediaID) { batch.ids.append(key.mediaID) }
                batch.waiters[key.mediaID, default: []].append((waiter, continuation))
                batches[batchKey] = batch
                if batch.ids.count >= SammyMediaSources.maxIDs {
                    send(batchKey)
                } else if first {
                    Task {
                        try? await Task.sleep(for: Self.batchDelay)
                        await self.send(batchKey)
                    }
                }
            }
        } onCancel: {
            Task { await self.stopWaiting(batchKey, mediaID: key.mediaID, waiter: waiter) }
        }
    }

    /// A caller stopped waiting for an answer not yet asked for: it is
    /// answered nil at once, and an ID nobody waits for is left out.
    private func stopWaiting(_ batchKey: BatchKey, mediaID: String, waiter: Int) {
        guard var batch = batches[batchKey], var waiting = batch.waiters[mediaID],
              let index = waiting.firstIndex(where: { $0.id == waiter }) else { return }
        waiting.remove(at: index).continuation.resume(returning: nil)
        if waiting.isEmpty {
            batch.waiters[mediaID] = nil
            batch.ids.removeAll { $0 == mediaID }
        } else {
            batch.waiters[mediaID] = waiting
        }
        batches[batchKey] = batch.ids.isEmpty ? nil : batch
    }

    /// Sends the IDs waiting for `batchKey`, at most 50, in one request.
    private func send(_ batchKey: BatchKey) {
        guard let batch = batches.removeValue(forKey: batchKey), !batch.ids.isEmpty else { return }
        let ids = Array(batch.ids.prefix(SammyMediaSources.maxIDs))
        let keys = ids.compactMap { id in
            SammyMediaReference(accountID: accountID, feedID: batchKey.feedID, mediaID: id, thread: batchKey.thread).map(Key.init)
        }
        let task = Task { await self.ask(batchKey, ids: ids) }
        for key in keys { inFlight[key] = task }
        Task {
            let answered = await task.value
            for key in keys where inFlight[key] == task { inFlight[key] = nil }
            self.deliver(answered, to: batch)
        }
    }

    private func deliver(_ answered: [String: SammyDirectAnswer]?, to batch: Batch) {
        for (mediaID, waiting) in batch.waiters {
            for waiter in waiting { waiter.continuation.resume(returning: answered?[mediaID]) }
        }
    }

    /// `POST <server>/api/v1/feeds/<feed>/media-sources` for `ids`, with
    /// the account's credential, in one of the slots: the server's check
    /// takes one of the same. Its answers are kept. Nil on any failure, and
    /// a server that doesn't offer it isn't asked again for a while.
    private func ask(_ batchKey: BatchKey, ids: [String]) async -> [String: SammyDirectAnswer]? {
        guard let request = try? SammyMediaSources.request(server: account.server, feedID: batchKey.feedID, thread: batchKey.thread, ids: ids)
        else { return nil }
        let account = account, timeout = sourcesTimeout
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await inSlot(.attachment) {
                // A server that takes the batch and stalls gets `timeout`,
                // then the request is cancelled and its slot given back.
                let sending = Task.detached { try await account.send(request) }
                guard let answer = await withDeadline(timeout, { try? await sending.value }) else {
                    sending.cancel()
                    throw ConnectorError.offline
                }
                return answer
            }
        } catch {
            return nil
        }
        switch response.statusCode {
        case 200:
            guard let answered = try? SammyMediaSources.decode(data, ids: ids, now: now()) else { return nil }
            keep(answered, feedID: batchKey.feedID, thread: batchKey.thread)
            return answered
        case 429:
            _ = holdingBack(response, .attachment)
            return nil
        case 400, 403, 404, 405, 501:
            // A server without the route refuses it: read as before.
            sourcesUnsupportedUntil = now().addingTimeInterval(Self.unsupportedWait)
            return nil
        default:
            return nil
        }
    }

    private func keep(_ answered: [String: SammyDirectAnswer], feedID: String, thread: String?) {
        let current = now()
        if answers.count >= Self.cacheLimit {
            answers = answers.filter { $0.value.until > current }
            if answers.count >= Self.cacheLimit { answers.removeAll() }
        }
        for (mediaID, answer) in answered {
            guard let key = SammyMediaReference(accountID: accountID, feedID: feedID, mediaID: mediaID, thread: thread).map(Key.init)
            else { continue }
            let until: Date
            switch answer {
            case .direct(let source): until = source.expiresAt
            case .grant, .gone: until = current.addingTimeInterval(Self.answerLife)
            }
            answers[key] = KeptAnswer(answer: answer, until: until)
        }
    }

    /// The grant for `reference`'s attachment: the one kept, while it has
    /// more than `renewalMargin` left, else a new one.
    func grant(for reference: SammyMediaReference, kind: Kind = .attachment) async throws -> Grant {
        try await grant(Key(reference), kind: kind)
    }

    // MARK: Reading

    private func read(_ reference: SammyMediaReference, range: ClosedRange<Int>?, limit: Int, kind: Kind) async throws -> RangedResponse {
        let key = Key(reference)
        var grant = try await grant(key, kind: kind)
        var renewed = false
        while true {
            let (data, response) = try await bytes(grant, preview: reference.preview, range: range, limit: limit, kind: kind)
            switch response.statusCode {
            case 200, 206:
                return try Self.checked(data, response, range: range, limit: limit)
            case 404, 410:
                // The grant has gone (expired, or its credential revoked):
                // one new grant, one more try.
                if grants[key] == grant { grants[key] = nil }
                guard !renewed else { throw ConnectorError.notFound }
                renewed = true
                grant = try await self.grant(key, kind: kind)
            case 429:
                tally.record(.bytesRateLimited, kind)
                throw holdingBack(response, kind)
            default:
                throw ConnectorError.badResponse("HTTP \(response.statusCode)")
            }
        }
    }

    /// The kept grant, else the one being asked for, else a new one. A
    /// caller that stops waiting leaves the ask, and the last to leave an
    /// ask not yet sent cancels it, so it is never sent. One already sent
    /// stays, so a later caller joins it rather than asking again. A
    /// picture and an attachment never share an ask, so an attachment
    /// never waits on a picture's slots, hold-back or allowance; they
    /// share the grant once it is kept.
    private func grant(_ key: Key, kind: Kind) async throws -> Grant {
        if let kept = grants[key], now() < kept.expiresAt.addingTimeInterval(-Self.renewalMargin) { return kept }
        let pendingKey = AskKey(key: key, kind: kind)
        let entry: Asking
        if var pending = asking[pendingKey] {
            pending.callers += 1
            asking[pendingKey] = pending
            entry = pending
        } else {
            nextAsk += 1
            let id = nextAsk
            entry = Asking(id: id, task: Task { try await self.asked(pendingKey, id: id) }, callers: 1)
            asking[pendingKey] = entry
        }
        return try await withTaskCancellationHandler {
            try await entry.task.value
        } onCancel: {
            Task { await self.leave(pendingKey, id: entry.id) }
        }
    }

    /// Asks for the grant and keeps it, then takes the ask off the list.
    private func asked(_ pendingKey: AskKey, id: Int) async throws -> Grant {
        defer { if asking[pendingKey]?.id == id { asking[pendingKey] = nil } }
        let grant = try await ask(pendingKey, id: id)
        remember(grant, for: pendingKey.key)
        return grant
    }

    /// One caller of an ask stopped waiting; the last one cancels it,
    /// unless it has been sent.
    private func leave(_ pendingKey: AskKey, id: Int) {
        guard var entry = asking[pendingKey], entry.id == id else { return }
        entry.callers -= 1
        if entry.callers > 0 || entry.sent {
            asking[pendingKey] = entry
        } else {
            asking[pendingKey] = nil
            entry.task.cancel()
        }
    }

    private func markSent(_ pendingKey: AskKey, id: Int) {
        if asking[pendingKey]?.id == id { asking[pendingKey]?.sent = true }
    }

    /// `POST <server>/api/v1/feeds/<feed>/media/<media>/grant`, with
    /// `?thread=<ref>` for an attachment read in a thread, with the
    /// account's credential and no body. A picture's spends its allowance.
    private func ask(_ pendingKey: AskKey, id: Int) async throws -> Grant {
        let key = pendingKey.key, kind = pendingKey.kind
        var url = account.server.appending(path: "api/v1/feeds").appending(path: key.feedID).appending(path: "media")
            .appending(path: key.mediaID).appending(path: "grant")
        if let thread = key.thread {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "thread", value: thread)]
            guard let withThread = components?.url else { throw ConnectorError.badResponse("not a thread reference") }
            url = withThread
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(RSSConnector.userAgent, forHTTPHeaderField: "User-Agent")
        let account = account, tally = tally, sent = request
        let (data, response) = try await inSlot(kind, spendingAllowance: kind == .avatar) {
            self.markSent(pendingKey, id: id)
            tally.record(.grants, kind)
            // Not cancelled once it is sent: the server has counted it, so
            // its grant is worth keeping.
            return try await Task.detached { try await account.send(sent) }.value
        }
        if response.statusCode == 429 {
            tally.record(.grantsRateLimited, kind)
            throw holdingBack(response, kind)
        }
        // A refusal is a feed read's: 401 is the account signed out, 404
        // an attachment, post or feed that is gone.
        try ConnectorError.check(response, now: now())
        guard response.statusCode == 200 else { throw ConnectorError.badResponse("HTTP \(response.statusCode)") }
        return try Self.grant(in: data, server: account.server, now: now())
    }

    /// The grant in a response body, when its URL is https on `server`,
    /// under the media path, with no query, and it hasn't expired.
    static func grant(in data: Data, server: URL, now: Date) throws -> Grant {
        struct Raw: Decodable {
            var url: String
            var expiresAt: String
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { throw ConnectorError.badResponse("not a media grant") }
        // The token is one plain segment, so no dot segment or encoded
        // slash can lead out of the media path once a server resolves it.
        let path = URL(string: raw.url)?.path(percentEncoded: true) ?? ""
        let token = path.hasPrefix(grantPath) ? String(path.dropFirst(grantPath.count)) : ""
        guard RichFeedPage.isSafeHTTPS(raw.url), let url = URL(string: raw.url), ServerAddress.isSameOrigin(url, server),
              SammyMediaReference.isMediaID(token, upTo: 512), url.query == nil, url.fragment == nil
        else { throw ConnectorError.badResponse("a media grant off the account's server") }
        guard let expiresAt = FeedDate.iso8601(raw.expiresAt), expiresAt > now else {
            throw ConnectorError.badResponse("a media grant with no time left")
        }
        return Grant(url: url, expiresAt: expiresAt)
    }

    /// The grant's URL, read with no credential over a connection of its
    /// own to the server's address, following no redirect and reading at
    /// most `limit` bytes of the body.
    private func bytes(_ grant: Grant, preview: Bool, range: ClosedRange<Int>?, limit: Int,
                       kind: Kind) async throws -> (Data, HTTPURLResponse) {
        guard let url = preview ? URL(string: grant.url.absoluteString + "?variant=preview") : grant.url else {
            throw ConnectorError.badResponse("not a media grant")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("image/*,video/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(RSSConnector.userAgent, forHTTPHeaderField: "User-Agent")
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        guard let host = url.host(), let resolved = await addresses.resolve(host),
              let address = resolved.first(where: { $0.count == 4 }) ?? resolved.first else { throw ConnectorError.offline }
        let http = http
        return try await inSlot(kind) { try await http.send(request, upTo: limit, at: address) }
    }

    /// What a 200 or 206 brought, once it is whole: no shorter than its
    /// `Content-Length` (or `limit`, where reading stopped), and a 206 only
    /// for a range asked for, starting where it starts and ending within
    /// it, with as many bytes as its `Content-Range` names.
    static func checked(_ data: Data, _ response: HTTPURLResponse, range: ClosedRange<Int>?, limit: Int) throws -> RangedResponse {
        let header = { (name: String) in response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespaces) }
        if let length = header("Content-Length").flatMap({ Int($0) }), data.count < min(length, limit) {
            throw ConnectorError.badResponse("a body shorter than its length")
        }
        if response.statusCode == 206 {
            guard let range, let span = contentRange(header("Content-Range")),
                  span.lowerBound == range.lowerBound, span.upperBound <= range.upperBound else {
                throw ConnectorError.badResponse("a range that wasn't asked for")
            }
            if data.count < min(span.count, limit) { throw ConnectorError.badResponse("a body shorter than its range") }
        }
        return RangedResponse(data: Data(data.prefix(limit)), statusCode: response.statusCode, contentType: header("Content-Type"),
                              totalLength: RangedResponse.totalLength(status: response.statusCode, contentLength: header("Content-Length"),
                                                                      contentRange: header("Content-Range")))
    }

    /// `bytes a-b/total`'s range, when it is one.
    static func contentRange(_ value: String?) -> ClosedRange<Int>? {
        guard let value, value.hasPrefix("bytes "),
              let span = value.dropFirst("bytes ".count).split(separator: "/").first,
              case let bounds = span.split(separator: "-"), bounds.count == 2,
              let lower = Int(bounds[0]), let upper = Int(bounds[1]), lower >= 0, upper >= lower else { return nil }
        return lower...upper
    }

    // MARK: Limits

    private func remember(_ grant: Grant, for key: Key) {
        if grants.count >= Self.cacheLimit {
            let current = now()
            grants = grants.filter { $0.value.expiresAt > current }
            if grants.count >= Self.cacheLimit { grants.removeAll() }
        }
        grants[key] = grant
    }

    /// The error for a 429, holding requests back until it allows: every
    /// request after an attachment's, and other pictures after a picture's.
    private func holdingBack(_ response: HTTPURLResponse, _ kind: Kind) -> ConnectorError {
        let current = now()
        let asked = ConnectorError.retryAfter(response, now: current) ?? current.addingTimeInterval(Self.firstBackoff)
        let until = min(asked, current.addingTimeInterval(Self.longestBackoff))
        switch kind {
        case .attachment: allHeldUntil = max(allHeldUntil ?? until, until)
        case .avatar: avatarsHeldUntil = max(avatarsHeldUntil ?? until, until)
        }
        return .rateLimited(retryAfter: until)
    }

    /// Throws `.rateLimited` while a 429 holds `kind` back.
    private func checkHeld(_ kind: Kind) throws {
        let current = now()
        let held = [allHeldUntil, kind == .avatar ? avatarsHeldUntil : nil].compactMap { $0 }.filter { current < $0 }.max()
        guard let held else { return }
        tally.record(.heldBack, kind)
        throw ConnectorError.rateLimited(retryAfter: held)
    }

    /// Runs `send` in one of the `streams` slots, once nothing holds
    /// `kind` back, and, when `spendingAllowance`, once the pictures'
    /// allowance gives a grant. An attachment waiting for a slot goes
    /// before any picture.
    private func inSlot<T: Sendable>(_ kind: Kind, spendingAllowance: Bool = false,
                                     _ send: () async throws -> T) async throws -> T {
        try checkHeld(kind)
        if canStart(kind) {
            take(kind)
        } else {
            // A slot passes straight from `release` to the waiter, counted.
            await withCheckedContinuation { continuation in
                switch kind {
                case .attachment: waitingAttachments.append(continuation)
                case .avatar: waitingAvatars.append(continuation)
                }
            }
        }
        defer { release(kind) }
        if Task.isCancelled { throw ConnectorError.offline }
        try checkHeld(kind)
        if spendingAllowance, let next = allowance.take(now: now()) {
            tally.record(.deferred, kind)
            throw ConnectorError.rateLimited(retryAfter: next)
        }
        return try await send()
    }

    /// How many wait for a slot, of each kind; for tests.
    var waitingForSlots: (attachments: Int, avatars: Int) { (waitingAttachments.count, waitingAvatars.count) }
    /// How many grants are being asked for; for tests.
    var asksOut: Int { asking.count }

    private func canStart(_ kind: Kind) -> Bool {
        inUse < Self.streams && (kind == .attachment || avatarsInUse < Self.avatarStreams)
    }

    private func take(_ kind: Kind) {
        inUse += 1
        if kind == .avatar { avatarsInUse += 1 }
    }

    /// Frees `kind`'s slot and hands it on: to the first attachment
    /// waiting, else to the first picture, when pictures may take one.
    private func release(_ kind: Kind) {
        inUse -= 1
        if kind == .avatar { avatarsInUse -= 1 }
        if !waitingAttachments.isEmpty {
            take(.attachment)
            waitingAttachments.removeFirst().resume()
        } else if !waitingAvatars.isEmpty, canStart(.avatar) {
            take(.avatar)
            waitingAvatars.removeFirst().resume()
        }
    }
}
