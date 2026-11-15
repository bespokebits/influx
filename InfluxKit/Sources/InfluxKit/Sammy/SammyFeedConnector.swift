import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Sammy connector for one connected account: each of the account's
/// feeds is a source, read with the account's token. An article feed's
/// posts are articles (`JSONFeedMapper`), merged as RSS articles are; a
/// rich feed's are posts (`RichFeedMapper`, ADR 0031). Which one a page is
/// comes only from the response (`SammyNegotiation`).
///
/// The token only ever goes to the account's server. A feed's URL is built
/// from the session's issuer and the feed's ID, never taken from the synced
/// `Source.url`; a listed feed URL or a next page on any other origin is
/// refused; and no request follows a redirect.
///
/// A feed's `.newer` fetch is conditional on its last `ETag`, kept with the
/// `Accept` it was sent with and the format it named, so an unchanged feed
/// costs a 304. When the feed has changed and the source has been fetched
/// before, it reads back through the next pages until it reaches a post it
/// already has or the retention window's start, so a reader who was away
/// misses nothing. `.older` pages back the same way. A rich feed is newest
/// first by `publishedAt`, so a post the server learns of late (a repost of
/// an older post) can enter below the posts already read: once a feed offers
/// a since link, `.newer` reads that instead, every page of it, and gets
/// every post that entered since the last read. The first time a feed offers
/// one, a source fetched before reads its whole window once, so posts missed
/// before then arrive too; of those, the store keeps only the ones newer than
/// it had and the ones that join a row it has (`FetchedPage.catchUpFrom`). A
/// since link the server stops serving is dropped
/// for a top read of the whole window, and links are held off for a while
/// after (`sinceFailure(_:after:)`, ADR 0031). Sammy feeds support no
/// post actions. A rich post's media is stored as references, whose bytes
/// `media` reads through short-lived grants. A rich post that names a
/// thread has one, read on demand from the thread route and never stored
/// (`thread(of:)`).
public struct SammyFeedConnector: Connector {
    /// How many pages one `.newer` fetch reads at most while catching up,
    /// far more than a month of posts. Paging back can't reach a gap above
    /// the stored posts, so a catch-up that stops here is kept in the
    /// cursor and the next `.newer` fetch carries on from where it stopped.
    static let maxCatchUpPages = 50

    public let account: SammyAccount
    public var accountID: String { account.accountID }
    /// The bytes of the account's rich post media, through grants asked
    /// for with the account's credential.
    public let media: SammyMediaGrants
    /// The threads read, with their validators, in memory only.
    let threads = SammyThreads()
    /// The dot colour new sources from this account start with.
    private let colorIndex: Int
    private let resolver: MediaResolver
    private let fetchLimit: Duration
    private let now: @Sendable () -> Date

    public init(account: SammyAccount, colorIndex: Int = 0, http: any HTTPClient = URLSession.shared, resolver: MediaResolver? = nil) {
        self.init(account: account, colorIndex: colorIndex, http: http, resolver: resolver, fetchLimit: RSSConnector.fetchLimit)
    }

    init(account: SammyAccount, colorIndex: Int = 0, http: any HTTPClient, resolver: MediaResolver? = nil, fetchLimit: Duration,
         addresses: AddressLookup = .system, now: @escaping @Sendable () -> Date = { Date() }, directMedia: MediaResolver? = nil,
         directSources: Bool = true) {
        self.account = account
        media = SammyMediaGrants(account: account, http: http, addresses: addresses, now: now, direct: directMedia,
                                 directSources: directSources)
        self.colorIndex = colorIndex
        self.resolver = resolver ?? MediaResolver(client: http)
        self.fetchLimit = fetchLimit
        self.now = now
    }

    public func handles(_ source: Source) -> Bool {
        source.kind == .sammyFeed && source.accountID == accountID
    }

    /// Every feed the account has that this build reads, in the server's
    /// order (`GET <issuer>/api/v1/feeds`).
    public func availableSources() async throws -> [Source] {
        let (data, response) = try await get(SammyFeedList.request(issuer: account.server))
        let list = try SammyFeedList.decode(data, response, now: Date())
        return Self.sources(of: list, accountID: accountID, issuer: account.server, colorIndex: colorIndex)
    }

    /// The sources for the feeds in `list`, in the server's order, each
    /// with what the list says its items are. A feed whose URL is on
    /// another origin is left out, as is one whose ID could make its source
    /// ID ambiguous or isn't one path segment.
    static func sources(of list: SammyFeedList, accountID: String, issuer: URL, colorIndex: Int) -> [Source] {
        list.feeds.compactMap { feed in
            guard SammyFeedList.isSafeID(feed.id), let url = URL(string: feed.feedURL),
                  ServerAddress.isSameOrigin(url, issuer) else { return nil }
            return Source(
                id: sourceID(accountID: accountID, feedID: feed.id), kind: .sammyFeed, accountID: accountID,
                title: feed.title?.nilIfEmpty ?? "Feed", url: url.absoluteString, colorIndex: colorIndex, itemKind: feed.itemKind
            )
        }
    }

    public func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage {
        guard handles(source), let id = Self.feedID(of: source.id, accountID: accountID), let url = feedURL(for: source) else {
            throw ConnectorError.notFound
        }
        let feed = Feed(id: id, url: url, accept: SammyNegotiation.accept(for: source.itemKind), expected: source.itemKind)
        switch request.direction {
        case .newer: return try await newer(request, feed, from: source)
        case .older: return try await older(request, feed, from: source)
        }
    }

    // MARK: Threads

    public func offersThread(of item: ItemReference) -> Bool {
        SammyThreadRef(actionRef: item.actionRef) != nil && Self.feedID(of: item.sourceID, accountID: accountID) != nil
    }

    /// The thread a rich post names: `GET <issuer>/api/v1/feeds/<feed
    /// id>/threads/<ref>` with the rich `Accept` and the account's
    /// credential, as a feed read is sent (the account's server only, no
    /// redirect), conditional on the validator of the last time it was
    /// read. Its posts come back as the thread view's and are never
    /// stored. A post that names no thread, or one of another account, is
    /// `.unsupported`; a 404 is `.notFound` (the thread, the post or the
    /// feed has gone, or the post is past the feed's window); a 406 is
    /// `.unsupported`; anything that isn't this version's thread about this
    /// post is `.badResponse`.
    public func thread(of item: ItemReference) async throws -> PostThread {
        guard let feedID = Self.feedID(of: item.sourceID, accountID: accountID),
              let ref = SammyThreadRef(actionRef: item.actionRef)?.ref else { throw ConnectorError.unsupported }
        let key = SammyThreads.Key(feedID: feedID, ref: ref)
        let kept = await threads.kept(key)
        let url = account.server.appending(path: "api/v1/feeds").appending(path: feedID).appending(path: "threads").appending(path: ref)
        let (data, response) = try await get(Self.feedRequest(url, accept: SammyNegotiation.rich, etag: kept?.etag))
        let fetchedAt = self.now()
        do {
            try SammyNegotiation.check(response, now: fetchedAt)
        } catch {
            if response.statusCode == 404 || response.statusCode == 410 { await threads.forget(key) }
            throw error
        }
        let thread: RichThread
        let etag = response.value(forHTTPHeaderField: "ETag")
        if response.statusCode == 304 {
            // No body and no `Content-Type`: the thread's own `ETag` is
            // the proof of format, and only a kept thread can be unchanged.
            guard let kept, etag?.hasPrefix(RichThread.etagPrefix) == true else {
                throw ConnectorError.badResponse("a 304 for another representation")
            }
            thread = kept.thread
        } else {
            guard response.statusCode == 200, SammyNegotiation.representation(of: response) == .rich else {
                throw ConnectorError.badResponse("not a rich thread")
            }
            thread = try RichThread.decode(data, ref: ref, focusID: item.remoteID)
            await threads.keep(thread, etag: etag.flatMap { $0.hasPrefix(RichThread.etagPrefix) ? $0 : nil }, for: key)
        }
        let source = Source(id: item.sourceID, kind: .sammyFeed, accountID: accountID, title: "", colorIndex: colorIndex, itemKind: .post)
        return thread.postThread(feedID: feedID, source: source, fetchedAt: fetchedAt)
    }

    /// `<issuer>/api/v1/feeds/<feed id>`, from the session and the source's
    /// ID; the synced `Source.url` is never sent the token.
    func feedURL(for source: Source) -> URL? {
        guard let feedID = Self.feedID(of: source.id, accountID: accountID) else { return nil }
        return account.server.appending(path: "api/v1/feeds").appending(path: feedID)
    }

    /// One feed being read: where it is, the `Accept` it is read with, and
    /// what its source says its items are.
    private struct Feed {
        var id: String
        var url: URL
        var accept: String
        var expected: Item.Kind?
    }

    private func newer(_ request: FetchRequest, _ feed: Feed, from source: Source) async throws -> FetchedPage {
        let validators = request.cursor.flatMap(Validators.init(cursor:))
        // A catch-up resumes only under the Accept it began with, and only
        // in a format the feed may hold: its page links belong to the
        // representation it was served in. Once what the feed is known to
        // hold rules that out, it starts again from the top page.
        if let validators, validators.accept == feed.accept, Self.mayHold(validators.format, feed),
           let resume = validators.resume.flatMap(sameOrigin) {
            return try await resuming(validators, at: resume, feed, from: source, request: request)
        }
        if let validators, validators.accept == feed.accept, validators.format == .rich, feed.expected != .article,
           let since = validators.since.flatMap(sameOrigin) {
            return try await sinceRead(validators, at: since, feed, from: source, request: request)
        }
        // A validator is only good for the representation it came with. Once
        // a hold on since links is over, the top page is read whole, so its
        // link is seen even when nothing above the stored posts has changed.
        let holdIsOver = validators?.sinceHeldUntil.map { $0 <= request.now } ?? false
        let etag = holdIsOver ? nil : validators.flatMap { $0.accept == feed.accept ? $0.etag : nil }
        return try await topRead(validators, etag: etag, feed, from: source, request: request)
    }

    /// The feed's top page and, for a source fetched before, the catch-up
    /// below it. Without `failure` it takes the since link the page offers,
    /// unless since links are held off. With one, it stands in for a since
    /// read that failed (`SinceFailure`).
    private func topRead(_ validators: Validators?, etag: String?, _ feed: Feed, from source: Source, request: FetchRequest,
                         standingIn failure: SinceFailure? = nil) async throws -> FetchedPage {
        let (data, response) = try await get(Self.feedRequest(feed.url, accept: feed.accept, etag: etag))
        try SammyNegotiation.check(response, now: request.now)
        if response.statusCode == 304 {
            guard etag != nil, let validators, Self.notModified(response, matches: validators.format) else {
                throw ConnectorError.badResponse("a 304 for another representation")
            }
            return FetchedPage(items: [], newer: request.cursor, older: nil)
        }
        let first = try parse(data, response, feed)
        let storable = Self.storableETag(response, format: first.format)
        var next: Validators
        let readsAll: Bool
        switch failure {
        case nil:
            let held = validators?.sinceHeldUntil.flatMap { $0 > request.now ? $0 : nil }
            let since = held == nil ? first.sinceURL.flatMap(sameOrigin)?.absoluteString : nil
            next = Validators(etag: storable, accept: feed.accept, format: first.format, since: since)
            next.sinceHeldUntil = held
            next.sinceDrops = validators?.sinceDrops
            guard request.cursor != nil else {
                // A first fetch is one page; older ones come with `.older`.
                let items = await items(from: first, source: source, request: request)
                return FetchedPage(items: items, identities: Self.identities(from: first, source: source), newer: next.cursor, older: older(first, request))
            }
            // The first since link a source fetched before is offered, or the
            // first after one was dropped: posts that entered below the ones
            // it has may be missing, so read the whole window once, whatever
            // the source already has.
            readsAll = since != nil && validators?.since == nil
        case .dropped:
            // Posts may have entered below the ones the source has since the
            // last since read that worked, so read the whole window, and take
            // no since link for a while.
            let drops = (validators?.sinceDrops ?? 0) + 1
            next = Validators(etag: storable, accept: feed.accept, format: first.format)
            next.sinceDrops = drops
            next.sinceHeldUntil = request.now.addingTimeInterval(Self.sinceHoldOff(afterDrops: drops))
            readsAll = true
        case .failed(let count):
            // The since link is kept, with its own validator: its next read
            // that works still answers every post since its token, so this
            // read only stops at the first post the source has.
            guard let validators, first.format == .rich else {
                throw ConnectorError.badResponse("a since read's stand-in answered as an article feed")
            }
            next = validators
            next.sinceFailures = count
            readsAll = false
        }
        let (page, unfinished) = try await catchingUp(from: first, feed, request: request, readsAll: readsAll)
        let items = await items(from: page, source: source, request: request)
        // A read of the whole window brings every post in it, days of older
        // ones the source never had among them: only those newer than what
        // it has, and those that join a row the reader has, are new to them
        // (`FetchedPage.catchUpFrom`). With nothing stored, all of them are.
        let catchUpFrom = readsAll ? request.newestStored ?? .distantPast : nil
        next.resume = unfinished
        next.readsAll = unfinished != nil && readsAll ? true : nil
        next.catchUpFrom = unfinished != nil ? catchUpFrom : nil
        return FetchedPage(items: items, identities: Self.identities(from: page, source: source), newer: next.cursor, older: nil,
                           catchUpFrom: catchUpFrom)
    }

    /// The posts that entered the feed since the last read, from the since
    /// link it gave, conditional on that link's last `ETag`. A page that
    /// carries a new since link is read to its end: it holds only posts that
    /// entered after the token, so one the source already has is no reason to
    /// stop. One without a link gives no token: the old one is kept and read
    /// again, and its pages stop as a top read's do. A read that says the
    /// link is no longer served falls back to the top page
    /// (`sinceFailure(_:after:)`).
    private func sinceRead(_ validators: Validators, at url: URL, _ feed: Feed, from source: Source, request: FetchRequest) async throws -> FetchedPage {
        let (data, response) = try await get(Self.feedRequest(url, accept: feed.accept, etag: validators.etag))
        if let failure = Self.sinceFailure(response, after: validators.sinceFailures ?? 0) {
            // The stored validator is the since link's, never the top page's.
            return try await topRead(validators, etag: nil, feed, from: source, request: request, standingIn: failure)
        }
        try SammyNegotiation.check(response, now: request.now)
        var next = validators
        // A since read that works ends the failures before it.
        next.sinceFailures = nil
        next.sinceDrops = nil
        if response.statusCode == 304 {
            guard validators.etag != nil, Self.notModified(response, matches: .rich) else {
                throw ConnectorError.badResponse("a 304 for another representation")
            }
            return FetchedPage(items: [], newer: next == validators ? request.cursor : next.cursor, older: nil)
        }
        let first = try parse(data, response, feed)
        guard first.format == .rich else { throw ConnectorError.badResponse("a since read answered as an article feed") }
        let offered = first.sinceURL.flatMap(sameOrigin)?.absoluteString
        let (page, unfinished) = try await catchingUp(from: first, feed, request: request, readsAll: offered != nil)
        let items = await items(from: page, source: source, request: request)
        next.since = offered ?? validators.since
        // A validator is only good for the link it was answered for.
        next.etag = next.since == url.absoluteString ? Self.storableETag(response, format: .rich) : nil
        next.resume = unfinished
        next.readsAll = unfinished != nil && offered != nil ? true : nil
        // Its pages hold only posts that entered after the token, so the
        // catch-up that carries it on is no read of the whole window.
        next.readsSince = next.readsAll
        next.catchUpFrom = nil
        return FetchedPage(items: items, identities: Self.identities(from: page, source: source), newer: next.cursor, older: nil)
    }

    /// How many server errors in a row from since reads, each while the top
    /// page could still be read, drop the since link.
    static let sinceFailureLimit = 3

    /// A since read's failure that the top page stands in for.
    enum SinceFailure: Equatable {
        /// The link is no longer served: drop it, read the whole window, and
        /// hold since links off for a while.
        case dropped
        /// A server error, the `count`th in a row and below
        /// `sinceFailureLimit`: keep the link and read the top page as usual.
        case failed(count: Int)
    }

    /// What a since read's `response` says about its link, after `failures`
    /// server errors in a row before it. A 400 (the contract's refusal of a
    /// token), 404 or 410 says the link is no longer served. A server error
    /// is counted, and the `sinceFailureLimit`th says the same: a feed
    /// source rolled back to a build without since reads answers every one
    /// with a 502. Anything else, including a 429 or a 503 with
    /// `Retry-After`, is nil: it fails as any read does, with the usual
    /// backoff, and the link is kept. The top read the failure falls back to
    /// must work for it to count: when the server can't answer that either,
    /// its failure is the fetch's.
    static func sinceFailure(_ response: HTTPURLResponse, after failures: Int) -> SinceFailure? {
        switch response.statusCode {
        case 400, 404, 410:
            return .dropped
        case 503 where response.value(forHTTPHeaderField: "Retry-After") != nil:
            return nil
        case 500..<600:
            let count = failures + 1
            return count >= sinceFailureLimit ? .dropped : .failed(count: count)
        default:
            return nil
        }
    }

    /// How long since links are held off after the `drops`th drop in a row:
    /// an hour, doubling with each drop that follows the link's return, up to
    /// a day. Each return costs a whole-window read, so a server that offers
    /// links it can't serve costs a few of those a day, not one a refresh.
    static func sinceHoldOff(afterDrops drops: Int) -> TimeInterval {
        let hours = 1 << min(max(drops, 1) - 1, 5)
        return TimeInterval(min(hours, 24) * 3600)
    }

    /// Carries on a catch-up that stopped at `maxCatchUpPages`, from the
    /// page it stopped before. The validator of the feed's top page, read
    /// when the catch-up began, stays in the cursor for the fetch after it.
    private func resuming(_ validators: Validators, at url: URL, _ feed: Feed, from source: Source, request: FetchRequest) async throws -> FetchedPage {
        let (data, response) = try await get(Self.feedRequest(url, accept: feed.accept, etag: nil))
        try SammyNegotiation.check(response, now: request.now)
        let first = try parse(data, response, feed)
        // Cursors from before formats were kept are article feeds'.
        guard first.format == validators.format ?? .article else {
            throw ConnectorError.badResponse("a catch-up that mixes formats")
        }
        let readsAll = validators.readsAll == true
        let (page, unfinished) = try await catchingUp(from: first, feed, request: request, readsAll: readsAll)
        let items = await items(from: page, source: source, request: request)
        // A read of the whole window carries on from where it began. One
        // a build before catch-ups were told apart left unfinished says
        // neither, and is taken as one, from what the source has now: of
        // the two, a since read's late posts are what that can lose, and
        // only those that join no row.
        let catchUpFrom = readsAll && validators.readsSince != true ? validators.catchUpFrom ?? request.newestStored ?? .distantPast : nil
        var next = validators
        next.resume = unfinished
        next.readsAll = unfinished != nil && readsAll ? true : nil
        next.readsSince = unfinished != nil ? validators.readsSince : nil
        next.catchUpFrom = unfinished != nil ? catchUpFrom : nil
        return FetchedPage(items: items, identities: Self.identities(from: page, source: source), newer: next.cursor, older: nil,
                           catchUpFrom: catchUpFrom)
    }

    /// `first` and the pages after it, read through each page's next page
    /// until one holds a post the source already has (unless `readsAll`),
    /// reaches past the retention window or is the last, or
    /// `maxCatchUpPages` pages have been read. The address of the page it
    /// stopped before comes back when it stopped only for the page limit.
    /// Every page must be of the first one's format.
    private func catchingUp(from first: SammyPage, _ feed: Feed, request: FetchRequest, readsAll: Bool = false) async throws -> (SammyPage, unfinished: String?) {
        var all = first
        var page = first
        var read = 1
        while true {
            guard readsAll || !page.holdsAny(of: request.storedRemoteIDs), let next = nextURL(of: page),
                  page.mayReachFurther(notBefore: request.notBefore)
            else { return (all, nil) }
            guard read < Self.maxCatchUpPages else { return (all, next.absoluteString) }
            let (data, response) = try await get(Self.feedRequest(next, accept: feed.accept, etag: nil))
            try SammyNegotiation.check(response, now: request.now)
            page = try parse(data, response, feed)
            guard page.format == first.format else { throw ConnectorError.badResponse("a catch-up that mixes formats") }
            all.append(page)
            read += 1
        }
    }

    private func older(_ request: FetchRequest, _ feed: Feed, from source: Source) async throws -> FetchedPage {
        guard let url = request.cursor.flatMap({ sameOrigin($0.rawValue) }) else {
            return FetchedPage(items: [], newer: nil, older: nil)
        }
        let (data, response) = try await get(Self.feedRequest(url, accept: feed.accept, etag: nil))
        // An older page link belongs to the representation it was served
        // in. One saved before the feed's classification changed may be
        // refused, or answered in the other format; that ends the feed's
        // history rather than failing every refresh after it on a link
        // that can't be read.
        if response.statusCode == 406 || Self.isOtherRepresentation(response, than: feed) {
            return FetchedPage(items: [], newer: nil, older: nil)
        }
        try SammyNegotiation.check(response, now: request.now)
        let page = try parse(data, response, feed)
        let items = await items(from: page, source: source, request: request)
        return FetchedPage(items: items, identities: Self.identities(from: page, source: source), newer: nil, older: older(page, request))
    }

    private func items(from page: SammyPage, source: Source, request: FetchRequest) async -> [Item] {
        switch page {
        case .article(let feed):
            return await JSONFeedMapper.items(from: feed, source: source, fetchedAt: request.now, stored: request.storedRemoteIDs, resolver: resolver)
        case .rich(let rich):
            return RichFeedMapper.items(from: rich, source: source, fetchedAt: request.now)
        }
    }

    /// A rich page's posts' identities, for the store's joins; an article
    /// page has none.
    private static func identities(from page: SammyPage, source: Source) -> [String: [String]] {
        guard case .rich(let rich) = page else { return [:] }
        return RichFeedMapper.identities(from: rich, source: source)
    }

    /// The page after `page`, when it is on the account's server.
    private func nextURL(of page: SammyPage) -> URL? {
        page.nextURL.flatMap(sameOrigin)
    }

    /// `address` as a URL, when it is on the account's server.
    private func sameOrigin(_ address: String) -> URL? {
        guard let url = URL(string: address), ServerAddress.isSameOrigin(url, account.server) else { return nil }
        return url
    }

    /// The page before `page`, unless it is the last or already reaches
    /// back past the retention window.
    private func older(_ page: SammyPage, _ request: FetchRequest) -> Cursor? {
        guard let next = nextURL(of: page), page.mayReachFurther(notBefore: request.notBefore) else { return nil }
        return Cursor(rawValue: next.absoluteString)
    }

    // MARK: Responses

    /// The page in a 200 response, by its `Content-Type` and its body. A
    /// rich response must be a rich page of this version for this feed; an
    /// article response must be JSON Feed with no `format`. A source known
    /// to hold posts is never read as articles, nor one known to hold
    /// articles as posts, and a response that is neither is refused.
    /// Whether a page saved in `format` can be the feed's, given what it is
    /// known to hold. An unknown format or kind rules nothing out.
    private static func mayHold(_ format: SammyPage.Format?, _ feed: Feed) -> Bool {
        switch (format, feed.expected) {
        case (.rich?, .article?), (.article?, .post?): false
        default: true
        }
    }

    /// Whether a 2xx `response` is in the representation other than the
    /// one the feed is known to hold.
    private static func isOtherRepresentation(_ response: HTTPURLResponse, than feed: Feed) -> Bool {
        guard (200..<300).contains(response.statusCode), let expected = feed.expected else { return false }
        switch SammyNegotiation.representation(of: response) {
        case .rich?: return expected == .article
        case .article?: return expected == .post
        case nil: return false
        }
    }

    private func parse(_ data: Data, _ response: HTTPURLResponse, _ feed: Feed) throws -> SammyPage {
        switch SammyNegotiation.representation(of: response) {
        case .rich?:
            guard feed.expected != .article else { throw ConnectorError.badResponse("an article feed answered with posts") }
            return .rich(try RichFeedPage.decode(data, feedID: feed.id, feedURL: feed.url))
        case .article?:
            guard feed.expected != .post else { throw ConnectorError.badResponse("a rich feed answered as an article feed") }
            guard SammyNegotiation.isArticleBody(data) else { throw ConnectorError.badResponse("not a JSON Feed") }
            do {
                return .article(try JSONFeed.decode(data))
            } catch {
                throw ConnectorError.badResponse("not a JSON Feed")
            }
        case nil:
            throw ConnectorError.badResponse("an unknown content type")
        }
    }

    /// Whether a 304 is for the representation `format` was stored with.
    /// It has no body and no `Content-Type`, so its `ETag` is the proof: a
    /// rich one names the rich version, and an article one never does.
    static func notModified(_ response: HTTPURLResponse, matches format: SammyPage.Format?) -> Bool {
        let etag = response.value(forHTTPHeaderField: "ETag")
        switch format {
        case .rich?: return etag?.hasPrefix(SammyNegotiation.richETagPrefix) == true
        case .article?: return etag?.hasPrefix(SammyNegotiation.richETagPrefix) != true
        case nil: return false
        }
    }

    /// The response's `ETag`, when it can stand for a page of `format`: a
    /// rich one only with the rich version's prefix, an article one only
    /// without it.
    static func storableETag(_ response: HTTPURLResponse, format: SammyPage.Format) -> String? {
        guard let etag = response.value(forHTTPHeaderField: "ETag") else { return nil }
        let isRich = etag.hasPrefix(SammyNegotiation.richETagPrefix)
        return (format == .rich) == isRich ? etag : nil
    }

    // MARK: Requests

    /// A feed page in the representation `accept` asks for, conditional on
    /// `etag`. The cache is skipped so a 304 comes back to us instead of
    /// being answered from a stale copy.
    static func feedRequest(_ url: URL, accept: String, etag: String?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(RSSConnector.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    /// Sends `request` with the account's token, giving up as `.offline`
    /// once `fetchLimit` has passed.
    private func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let account = account
        let answer = await withDeadline(fetchLimit) { () async -> Result<(Data, HTTPURLResponse), any Error>? in
            do {
                return .success(try await account.send(request))
            } catch {
                return .failure(error)
            }
        }
        guard let answer else {
            try Task.checkCancellation()
            throw ConnectorError.offline
        }
        return try answer.get()
    }

    /// What the next `.newer` fetch sends back: the feed's last `ETag`, the
    /// `Accept` it was fetched with and the format it named. Kept even
    /// without an `ETag`, since a cursor is what says the source has been
    /// fetched before and so should catch up. Cursors from before formats
    /// were kept have neither, so their `ETag` is not sent again.
    struct Validators: Codable, Hashable {
        var etag: String?
        /// The page a catch-up stopped before at `maxCatchUpPages`, to read
        /// on from at the next `.newer` fetch.
        var resume: String?
        var accept: String?
        var format: SammyPage.Format?
        /// The since link the feed last gave: where `.newer` reads the posts
        /// that entered after the last read. `etag` is then its validator.
        var since: String?
        /// Whether the catch-up `resume` carries on reads every page, not
        /// stopping at a post the source has: a since read, or the one full
        /// read of the window when a feed first offers a since link.
        var readsAll: Bool?
        /// How many since reads in a row have failed with a server error
        /// while the top page could be read (`sinceFailure(_:after:)`).
        var sinceFailures: Int?
        /// Since links offered before this time are not taken: one was
        /// dropped, and the server may offer links it can't serve.
        var sinceHeldUntil: Date?
        /// How many times in a row a since link has been dropped, with no
        /// since read that worked between; it sets the hold-off.
        var sinceDrops: Int?
        /// For the read of the whole window that `resume` carries on: the
        /// date of the newest item the source had when it began
        /// (`FetchedPage.catchUpFrom`), `.distantPast` when it had none.
        var catchUpFrom: Date?
        /// Whether the catch-up `resume` carries on is a since read's,
        /// which keeps every post it brings.
        var readsSince: Bool?

        init(etag: String?, resume: String? = nil, accept: String? = nil, format: SammyPage.Format? = nil, since: String? = nil) {
            self.etag = etag
            self.resume = resume
            self.accept = accept
            self.format = format
            self.since = since
        }

        init?(cursor: Cursor) {
            guard let decoded = try? JSONDecoder().decode(Validators.self, from: Data(cursor.rawValue.utf8)) else { return nil }
            self = decoded
        }

        enum CodingKeys: String, CodingKey {
            case etag, resume, accept, format, since, readsAll, sinceFailures, sinceHeldUntil, sinceDrops, catchUpFrom, readsSince
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            etag = try container.decodeIfPresent(String.self, forKey: .etag)
            resume = try container.decodeIfPresent(String.self, forKey: .resume)
            accept = try container.decodeIfPresent(String.self, forKey: .accept)
            // A format this build doesn't know names no representation it
            // could send the validator for.
            format = (try? container.decodeIfPresent(SammyPage.Format.self, forKey: .format)) ?? nil
            since = (try? container.decodeIfPresent(String.self, forKey: .since)) ?? nil
            readsAll = (try? container.decodeIfPresent(Bool.self, forKey: .readsAll)) ?? nil
            sinceFailures = (try? container.decodeIfPresent(Int.self, forKey: .sinceFailures)) ?? nil
            sinceHeldUntil = (try? container.decodeIfPresent(Date.self, forKey: .sinceHeldUntil)) ?? nil
            sinceDrops = (try? container.decodeIfPresent(Int.self, forKey: .sinceDrops)) ?? nil
            catchUpFrom = (try? container.decodeIfPresent(Date.self, forKey: .catchUpFrom)) ?? nil
            readsSince = (try? container.decodeIfPresent(Bool.self, forKey: .readsSince)) ?? nil
        }

        var cursor: Cursor {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = (try? encoder.encode(self)) ?? Data()
            return Cursor(rawValue: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: IDs

    /// `sammy:<account id>:feed:<feed id>`, where the account ID is
    /// `<subject>@<host>` (`SammySession.accountID`).
    public static func sourceID(accountID: String, feedID: String) -> String {
        "sammy:\(accountID):feed:\(feedID)"
    }

    /// The feed ID in `sourceID`, when it is one of `accountID`'s and safe
    /// to put in a path.
    static func feedID(of sourceID: String, accountID: String) -> String? {
        let prefix = "sammy:\(accountID):feed:"
        guard sourceID.hasPrefix(prefix) else { return nil }
        let id = String(sourceID.dropFirst(prefix.count))
        return !id.isEmpty && SammyFeedList.isSafeID(id) ? id : nil
    }
}

/// A page of a Sammy feed, in whichever format the server answered.
enum SammyPage: Sendable, Hashable {
    case article(JSONFeed)
    case rich(RichFeedPage)

    /// What a validator is stored with: the format its page named.
    enum Format: String, Codable, Sendable, Hashable {
        case article
        case rich = "rich/1"
    }

    var format: Format {
        switch self {
        case .article: .article
        case .rich: .rich
        }
    }

    /// The page after this one, as the server gave it. The connector
    /// follows it only on the account's server.
    var nextURL: String? {
        switch self {
        case .article(let feed): feed.nextURL
        case .rich(let page): page.nextURL
        }
    }

    /// Where the posts that enter after this read are read from: a rich
    /// page's since link, when it has one.
    var sinceURL: String? {
        guard case .rich(let page) = self else { return nil }
        return page.sinceURL
    }

    /// Whether the page holds an item the source already has.
    func holdsAny(of stored: Set<String>) -> Bool {
        switch self {
        case .article(let feed):
            feed.items.contains { $0.id.map { stored.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? false }
        case .rich(let page):
            page.posts.contains { stored.contains($0.id) }
        }
    }

    /// Whether the page after this one may still hold items the retention
    /// window keeps. An article page must have items, and its oldest dated
    /// one not be past the window's start; undated items can't say, so
    /// they don't stop paging. A rich page with no posts can still have a
    /// next page (posts held back until they are due), so only its next
    /// page's absence ends it.
    func mayReachFurther(notBefore: Date) -> Bool {
        switch self {
        case .article(let feed):
            guard !feed.items.isEmpty else { return false }
            return feed.items.compactMap({ $0.datePublished ?? $0.dateModified }).min().map { $0 >= notBefore } ?? true
        case .rich(let page):
            return page.posts.map(\.publishedAt).min().map { $0 >= notBefore } ?? true
        }
    }

    /// Adds `other`'s items after this page's, and takes its next page.
    /// Both are of one format (`catchingUp` checks).
    mutating func append(_ other: SammyPage) {
        switch (self, other) {
        case (.article(var feed), .article(let more)):
            feed.items += more.items
            feed.nextURL = more.nextURL
            self = .article(feed)
        case (.rich(var page), .rich(let more)):
            page.posts += more.posts
            page.nextURL = more.nextURL
            self = .rich(page)
        default:
            break
        }
    }
}

/// `GET /api/v1/feeds`: the account and the feeds it offers.
struct SammyFeedList: Decodable, Sendable {
    /// The format and version of a rich list.
    static let richFormat = "sammy.rich-feed-list"
    static let richVersion = 1

    struct Account: Decodable, Sendable {
        /// The account's subject for this client. Sent only to an OAuth
        /// client's token; nil for other callers.
        var id: String?
        var server: String?

        enum CodingKeys: String, CodingKey { case id, server }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let subject: String? = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil
            id = subject?.isEmpty == false ? subject : nil
            server = (try? container.decodeIfPresent(String.self, forKey: .server)) ?? nil
        }
    }

    struct Feed: Decodable, Sendable {
        struct Classification: Decodable, Sendable {
            var kind: String?
        }

        var id: String
        var key: String?
        var title: String?
        var description: String?
        var feedURL: String
        var lastPostAt: Date?
        /// A rich list's `format`, `version` and `classification`; nil in an
        /// article list.
        var format: String?
        var version: Int?
        var classification: Classification?
        /// What the feed's items are, from a rich list's entry: nil in an
        /// article list, which doesn't say (`SammyFeedList.decode`).
        var itemKind: Item.Kind?

        enum CodingKeys: String, CodingKey {
            case id, key, title, description, lastPostAt, format, version, classification
            case feedURL = "feedUrl"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            guard !id.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "empty ID")
            }
            key = try? container.decodeIfPresent(String.self, forKey: .key)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            feedURL = try container.decode(String.self, forKey: .feedURL)
            let posted: String? = (try? container.decodeIfPresent(String.self, forKey: .lastPostAt)) ?? nil
            lastPostAt = posted.flatMap(FeedDate.iso8601)
            format = (try? container.decodeIfPresent(String.self, forKey: .format)) ?? nil
            version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? nil
            classification = (try? container.decodeIfPresent(Classification.self, forKey: .classification)) ?? nil
        }

        /// This entry of a rich list with its items' kind, or nil for a
        /// format, version or classification this build doesn't read.
        var classified: Feed? {
            var feed = self
            switch (format, classification?.kind) {
            case ("rich", "post") where version == 1:
                feed.itemKind = .post
            // An article entry is defined unversioned; one with a version
            // is a later format this build doesn't read.
            case ("article", "article") where version == nil:
                feed.itemKind = .article
            default:
                return nil
            }
            return feed
        }
    }

    var account: Account
    var feeds: [Feed]

    /// Whether `id` is only ASCII letters, digits and `._~-`, so it can't
    /// run into the next part of an account or source ID, or out of a path
    /// segment.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._~-".unicodeScalars.contains(scalar))
        }
    }

    enum CodingKeys: String, CodingKey { case account, feeds }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decode(Account.self, forKey: .account)
        // A feed that doesn't decode is left out, not the whole list.
        feeds = try container.decode([Lenient<Feed>].self, forKey: .feeds).compactMap(\.value)
    }

    /// The list, asking for the rich one: a server that serves rich feeds
    /// answers with every feed, and one that doesn't with its article list.
    static func request(issuer: URL) -> URLRequest {
        var request = URLRequest(url: issuer.appending(path: "api/v1/feeds"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(SammyNegotiation.either, forHTTPHeaderField: "Accept")
        return request
    }

    /// The list in a response to `request`, by its `Content-Type` and its
    /// body. A rich list must name its format and this version, and keeps
    /// only the feeds this build reads; an article list must name no
    /// format, and doesn't say what its feeds hold. Anything else is
    /// `.badResponse`, and a 406 `.unsupported`.
    static func decode(_ data: Data, _ response: HTTPURLResponse, now: Date) throws -> SammyFeedList {
        try SammyNegotiation.check(response, now: now)
        let representation = SammyNegotiation.representation(of: response)
        switch representation {
        case .rich?:
            let envelope = SammyNegotiation.Envelope.of(data)
            guard envelope?.format == richFormat, envelope?.version == richVersion else {
                throw ConnectorError.badResponse("a feed list of another format or version")
            }
        case .article?:
            guard SammyNegotiation.isArticleBody(data) else { throw ConnectorError.badResponse("undecodable feed list") }
        case nil:
            throw ConnectorError.badResponse("an unknown content type")
        }
        var list: SammyFeedList
        do {
            list = try decode(data)
        } catch {
            throw ConnectorError.badResponse("undecodable feed list: \(error)")
        }
        if representation == .rich {
            list.feeds = list.feeds.compactMap(\.classified)
        } else {
            for index in list.feeds.indices { list.feeds[index].itemKind = nil }
        }
        return list
    }

    /// The fields of a list body, however it was served.
    static func decode(_ data: Data) throws -> SammyFeedList {
        try JSONDecoder().decode(SammyFeedList.self, from: data)
    }
}
