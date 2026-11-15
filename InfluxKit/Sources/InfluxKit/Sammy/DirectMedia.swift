import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a rich post's media may be loaded straight from its source's public
/// media servers, as the account's server says (ADR 0040), and at what sizes.
/// Influx treats these as opaque public URLs: it never names or recognises
/// the source. They carry no credential, and none is ever sent to them.
public struct SammyDirectSource: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case image, video, gif
    }

    /// One size of an image on the source's servers.
    public struct Image: Sendable, Hashable {
        public var url: URL
        public var width: Int
        public var height: Int

        var longestSide: Int { max(width, height) }
    }

    /// One MP4 rendition of a video or GIF; `bitrate` in bits a second, 0
    /// when the source gives none.
    public struct Video: Sendable, Hashable {
        public var url: URL
        public var width: Int
        public var height: Int
        public var bitrate: Int
    }

    public var kind: Kind
    /// When the URLs may no longer be used.
    public var expiresAt: Date
    /// An image's sizes, smallest longest side first.
    public var images: [Image]
    /// A video's or GIF's renditions, lowest bitrate first.
    public var videos: [Video]
    /// A video's or GIF's still, smallest first; may be empty.
    public var preview: [Image]

    /// The bitrate a video plays at when the source offers one at or under
    /// it, as the grant's bytes would be: the source's best under it, else
    /// its lowest above it.
    static let videoBitrate = 2_200_000

    /// The image to load to draw `pixels` on the longest side: the smallest
    /// at least that large, else the largest there is. A row asks for the
    /// size it draws and the image viewer for the image's own size, so only
    /// the viewer loads the full size. For a preview, from the still's sizes.
    func image(forPixels pixels: Int, preview: Bool) -> Image? {
        let sizes = (preview ? self.preview : images).sorted { $0.longestSide < $1.longestSide }
        return sizes.first { $0.longestSide >= pixels } ?? sizes.last
    }

    /// The rendition to play: the best at or under `videoBitrate`, else the
    /// lowest above it.
    var video: Video? {
        videos.filter { $0.bitrate <= Self.videoBitrate }.max { $0.bitrate < $1.bitrate }
            ?? videos.min { $0.bitrate < $1.bitrate }
    }
}

/// What the account's server said about one media ID (ADR 0040).
enum SammyDirectAnswer: Sendable, Hashable {
    /// Load it from these public URLs until they expire.
    case direct(SammyDirectSource)
    /// Read it through a grant, as before.
    case grant
    /// The server has no such media for this feed (a grant would be a 404).
    case gone
}

/// `POST <server>/api/v1/feeds/<feed>/media-sources`: where up to 50 of a
/// feed's media IDs may be loaded directly (ADR 0040, the server's rich feed
/// contract § Direct sources).
enum SammyMediaSources {
    static let maxIDs = 50
    /// Sizes or renditions one ID may list, per list.
    static let listMax = 8
    static let dimensionMax = 16_384
    static let urlMax = 2048
    /// Where the batch goes on the server, after the feed's own path.
    static let pathComponent = "media-sources"

    /// The request for `ids` of `feedID` (and its thread, for a thread's
    /// media), with the account's credential added by `SammyAccount.send`.
    static func request(server: URL, feedID: String, thread: String?, ids: [String]) throws -> URLRequest {
        var url = server.appending(path: "api/v1/feeds").appending(path: feedID).appending(path: pathComponent)
        if let thread {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "thread", value: thread)]
            guard let withThread = components?.url else { throw ConnectorError.badResponse("not a thread reference") }
            url = withThread
        }
        // `SammyMediaGrants.sourcesTimeout` bounds the whole exchange; this
        // only stops a quiet connection sooner.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RSSConnector.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids], options: [.sortedKeys])
        return request
    }

    /// The answer for each of `ids`, from a 200 body that holds exactly one
    /// entry per ID, in the order asked. An entry that isn't exactly right
    /// is `.grant`, and a size or rendition that isn't, or whose URL fails
    /// `safeURL`, is left out; a body that isn't one entry per ID is a bad
    /// response, and every ID then reads through a grant. `expiresAt` must be
    /// in the future.
    static func decode(_ data: Data, ids: [String], now: Date) throws -> [String: SammyDirectAnswer] {
        // Field names from the JSON as sent; values through Codable, which
        // refuses a Bool or a fraction where a whole number belongs on every
        // platform.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], raw.count == 1,
              let rawEntries = raw["media"] as? [Any], rawEntries.count == ids.count,
              let body = try? JSONDecoder().decode(Body.self, from: data), body.media.count == ids.count else {
            throw ConnectorError.badResponse("not media sources")
        }
        var answers: [String: SammyDirectAnswer] = [:]
        for ((id, rawEntry), entry) in zip(zip(ids, rawEntries), body.media) {
            guard let keys = (rawEntry as? [String: Any]).map({ Set($0.keys) }), entry.id == id else {
                throw ConnectorError.badResponse("media sources for other IDs")
            }
            answers[id] = answer(entry, keys: keys, now: now)
        }
        return answers
    }

    private struct Body: Decodable {
        var media: [Entry]
    }

    private struct Entry: Decodable {
        var id: String?
        var use: String?
        var kind: String?
        var expiresAt: String?
        var images: Lenient<[Lenient<Size>]>?
        var videos: Lenient<[Lenient<Rendition>]>?
        var preview: Lenient<[Lenient<Size>]>?
    }

    private struct Size: Decodable {
        var url: String
        var width: Int
        var height: Int
    }

    private struct Rendition: Decodable {
        var url: String
        var width: Int
        var height: Int
        var bitrate: Int
    }

    /// A value that is nil, rather than failing what holds it, when it
    /// doesn't decode.
    private struct Lenient<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: any Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Value.self)
        }
    }

    private static func answer(_ entry: Entry, keys: Set<String>, now: Date) -> SammyDirectAnswer {
        switch entry.use {
        case "gone": return keys == ["id", "use"] ? .gone : .grant
        case "direct": break
        default: return .grant
        }
        guard keys.isSubset(of: ["id", "use", "kind", "expiresAt", "images", "videos", "preview"]),
              let kind = entry.kind.flatMap(SammyDirectSource.Kind.init(rawValue:)),
              let expiresAt = entry.expiresAt.flatMap(FeedDate.iso8601), expiresAt > now else { return .grant }
        let source = SammyDirectSource(kind: kind, expiresAt: expiresAt, images: images(entry.images), videos: videos(entry.videos),
                                       preview: images(entry.preview))
        switch kind {
        case .image: return source.images.isEmpty ? .grant : .direct(source)
        case .video, .gif: return source.videos.isEmpty ? .grant : .direct(source)
        }
    }

    private static func images(_ list: Lenient<[Lenient<Size>]>?) -> [SammyDirectSource.Image] {
        guard let list = list?.value, list.count <= listMax else { return [] }
        return list.compactMap { entry in
            guard let size = entry.value, let url = safeURL(size.url), isDimension(size.width), isDimension(size.height) else { return nil }
            return SammyDirectSource.Image(url: url, width: size.width, height: size.height)
        }
    }

    private static func videos(_ list: Lenient<[Lenient<Rendition>]>?) -> [SammyDirectSource.Video] {
        guard let list = list?.value, list.count <= listMax else { return [] }
        return list.compactMap { entry in
            guard let video = entry.value, let url = safeURL(video.url), isDimension(video.width), isDimension(video.height),
                  video.bitrate >= 0 else { return nil }
            return SammyDirectSource.Video(url: url, width: video.width, height: video.height, bitrate: video.bitrate)
        }
    }

    private static func isDimension(_ value: Int) -> Bool {
        (1...dimensionMax).contains(value)
    }

    /// A URL Influx may load itself: https, at most 2048 characters, no
    /// whitespace or backslash, no credential, no explicit port and no
    /// fragment, on a host name that could be public (`PublicAddress`). The
    /// address it resolves to is checked again, at every redirect, when it
    /// is loaded.
    static func safeURL(_ string: String) -> URL? {
        guard string.utf8.count <= urlMax, string.hasPrefix("https://"),
              !string.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "\\"
                  || CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: string), url.scheme == "https", let host = url.host(),
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              PublicAddress.isPublicName(host) else { return nil }
        return url
    }
}
