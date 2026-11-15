import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

/// The real client against a live Sammy server. Skipped unless
/// `SAMMY_LIVE_ORIGIN` (the server's address) and a read-only `feeds:read`
/// token are supplied, so CI never runs it and nothing here names a server.
/// The token comes from one of:
///
/// - `SAMMY_LIVE_TOKEN`: the token itself.
/// - `SAMMY_LIVE_TOKEN_FILE`: the path to an owner-only (0600) file holding
///   the token, either bare or as one `NAME=value` line, so the token never
///   passes through a shell variable. The file is read in-process, and the
///   test fails if it is unreadable, empty, a link, or open to group or
///   others (`LiveTokenFile`).
///
/// Set one, not both. The token is never printed; the test prints counts
/// only. It never revokes the token.
///
///     SAMMY_LIVE_ORIGIN=… SAMMY_LIVE_TOKEN=… swift test --filter SammyLiveTests
///     SAMMY_LIVE_ORIGIN=… SAMMY_LIVE_TOKEN_FILE=path/to/token swift test --filter SammyLiveTests
@Suite(.enabled(if: LiveServer.configured, "set SAMMY_LIVE_ORIGIN and SAMMY_LIVE_TOKEN or SAMMY_LIVE_TOKEN_FILE to run"))
struct SammyLiveTests {
    static let environment = LiveServer.environment

    @Test func theRealClientReadsALiveServer() async throws {
        let typed = try #require(Self.environment["SAMMY_LIVE_ORIGIN"])
        let token = try LiveServer.token()
        let origin = try #require(ServerAddress.origin(from: typed))
        let http = URLSession(configuration: .ephemeral)

        // Discovery: the issuer is exactly the typed origin.
        let oauth = try await SammySignIn(http: http, crypto: .live, credentials: InMemoryCredentialStore()).discover(server: typed)
        #expect(oauth.issuer == origin.absoluteString)
        #expect(oauth.server.revocationEndpoint != nil)

        // No revocation endpoint in this session, so nothing here can
        // revoke the token it was given.
        let session = SammySession(issuer: origin, revocationEndpoint: nil, accessToken: token, subject: "live")
        let credentials = InMemoryCredentialStore()
        try credentials.save(session, for: session.accountID)
        let account = SammyAccount(session: session, http: http, credentials: credentials)
        let connector = SammyFeedConnector(account: account, http: http)
        let sources = try await connector.availableSources()
        #expect(!sources.isEmpty)

        var items = 0, images = 0, pagedBack = 0, notModified = 0
        let now = Date()
        for source in sources {
            let first = try await connector.fetch(Refresher.request(for: source, direction: .newer, cursor: nil, now: now), from: source)
            items += first.items.count
            // The same feed again, with its validator, is a 304.
            let feedURL = try #require(connector.feedURL(for: source))
            let etag = try #require(first.newer.flatMap(SammyFeedConnector.Validators.init(cursor:))?.etag)
            let accept = SammyNegotiation.accept(for: source.itemKind)
            let (_, again) = try await account.send(SammyFeedConnector.feedRequest(feedURL, accept: accept, etag: etag))
            #expect(again.statusCode == 304)
            if again.statusCode == 304 { notModified += 1 }
            let refetched = try await connector.fetch(Refresher.request(for: source, direction: .newer, cursor: first.newer, now: now), from: source)
            #expect(refetched.items.isEmpty && refetched.newer == first.newer)
            // A `next_url` page, where the feed has one.
            if let older = first.older {
                let page = try await connector.fetch(Refresher.request(for: source, direction: .older, cursor: older, now: now), from: source)
                pagedBack += page.items.isEmpty ? 0 : 1
            }
            // Every image is on a public https host the media path accepts.
            // Rich posts carry none.
            let (data, response) = try await account.send(SammyFeedConnector.feedRequest(feedURL, accept: accept, etag: nil))
            guard SammyNegotiation.representation(of: response) == .article else { continue }
            for image in try JSONFeed.decode(data).items.compactMap(\.image) {
                let url = try #require(URL(string: image))
                let host = try #require(url.host())
                #expect(url.scheme == "https")
                #expect(PublicAddress.isPublicName(host))
                let addresses = try #require(PublicAddress.addresses(of: host))
                #expect(!addresses.isEmpty && addresses.allSatisfy(PublicAddress.isPublic))
                images += 1
            }
        }
        print("SammyLiveTests: feeds=\(sources.count) items=\(items) notModified=\(notModified) pagedBack=\(pagedBack) images=\(images)")
    }
}

private enum LiveServer {
    static let environment = ProcessInfo.processInfo.environment
    static var configured: Bool {
        isSet("SAMMY_LIVE_ORIGIN") && (isSet("SAMMY_LIVE_TOKEN") || isSet("SAMMY_LIVE_TOKEN_FILE"))
    }

    struct BothTokenSources: Error, CustomStringConvertible {
        var description: String { "set SAMMY_LIVE_TOKEN or SAMMY_LIVE_TOKEN_FILE, not both" }
    }

    static func token() throws -> String {
        if let path = environment["SAMMY_LIVE_TOKEN_FILE"], !path.isEmpty {
            guard !isSet("SAMMY_LIVE_TOKEN") else { throw BothTokenSources() }
            return try LiveTokenFile.read(at: path)
        }
        return try #require(environment["SAMMY_LIVE_TOKEN"])
    }

    private static func isSet(_ name: String) -> Bool { !(environment[name] ?? "").isEmpty }
}

extension OAuthCrypto {
    /// The system's on Apple platforms; elsewhere only discovery runs, which
    /// needs no hashing.
    fileprivate static var live: OAuthCrypto {
        #if canImport(CryptoKit)
        .system
        #else
        .fake()
        #endif
    }
}
