import Foundation

/// The parts of the Mastodon REST API's entities that Influx reads. Field names
/// follow the API (decoded from snake_case); anything Influx doesn't use is
/// left out, so a server adding fields never breaks decoding.
public enum Mastodon {}

extension Mastodon {
    public struct Account: Codable, Sendable, Hashable {
        public var id: String
        /// `user` for an account on the same instance, `user@domain` otherwise.
        public var acct: String
        public var username: String
        public var displayName: String
        public var url: String?
        /// The profile picture, and a still of it for an animated one.
        public var avatar: String?
        public var avatarStatic: String?
    }

    public struct Status: Codable, Sendable, Hashable {
        public var id: String
        /// The ActivityPub URI: the same on every instance, so it is what
        /// makes two copies of a post the same post.
        public var uri: String
        public var url: String?
        public var createdAt: Date
        public var account: Account
        /// HTML.
        public var content: String
        public var spoilerText: String
        public var inReplyToId: String?
        public var inReplyToAccountId: String?
        public var mentions: [Mention]
        public var mediaAttachments: [MediaAttachment]
        public var card: Card?
        /// The post this one quotes (Mastodon 4.5 quote posts).
        public var quote: Quote?
        /// Set when this status is a boost; the boosted post is inside.
        public var reblog: Status? {
            get { _reblog?.value }
            set { _reblog = newValue.map(Box.init) }
        }
        /// The server-side filters this status matched, for the signed-in
        /// account.
        public var filtered: [FilterResult]?
        /// Whether the signed-in account has favourited, boosted or
        /// bookmarked it; only sent to a signed-in account.
        public var favourited: Bool?
        public var reblogged: Bool?
        public var bookmarked: Bool?

        private var _reblog: Box?

        enum CodingKeys: String, CodingKey {
            case id, uri, url, createdAt, account, content, spoilerText, inReplyToId, inReplyToAccountId
            case mentions, mediaAttachments, card, quote, filtered, favourited, reblogged, bookmarked
            case _reblog = "reblog"
        }

        /// Lets `Status` hold a `Status` while staying a value type.
        final class Box: Codable, Sendable, Hashable {
            let value: Status
            init(_ value: Status) { self.value = value }
            init(from decoder: any Decoder) throws { value = try Status(from: decoder) }
            func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
            static func == (lhs: Box, rhs: Box) -> Bool { lhs.value == rhs.value }
            func hash(into hasher: inout Hasher) { hasher.combine(value) }
        }
    }

    /// What `GET /api/v1/statuses/:id/context` returns.
    public struct Context: Codable, Sendable, Hashable {
        /// Oldest first.
        public var ancestors: [Status]
        /// In conversation order.
        public var descendants: [Status]
    }

    public struct Mention: Codable, Sendable, Hashable {
        public var id: String
        public var acct: String
        public var username: String
    }

    public struct MediaAttachment: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable {
            case image, gifv, video, audio, unknown

            public init(from decoder: any Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        public var id: String
        public var type: Kind
        public var url: String?
        public var previewUrl: String?
        public var description: String?
        public var meta: Meta?

        public struct Meta: Codable, Sendable, Hashable {
            public var original: Size?
            public var small: Size?
        }

        public struct Size: Codable, Sendable, Hashable {
            public var width: Double?
            public var height: Double?
            public var aspect: Double?
        }
    }

    /// A quote of another post. The quoted post is only sent once its
    /// author has accepted the quote, and a quoted post Influx can't read
    /// leaves the quote out rather than failing the whole status.
    public struct Quote: Codable, Sendable, Hashable {
        /// `accepted`, `pending`, `rejected`, `revoked`, `deleted`, …
        public var state: String?
        public var quotedStatus: Status? {
            get { _quotedStatus?.value }
            set { _quotedStatus = newValue.map(Status.Box.init) }
        }

        private var _quotedStatus: Status.Box?

        enum CodingKeys: String, CodingKey {
            case state
            case _quotedStatus = "quotedStatus"
        }

        public init(state: String?, quotedStatus: Status?) {
            self.state = state
            _quotedStatus = quotedStatus.map(Status.Box.init)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            state = try? container.decodeIfPresent(String.self, forKey: .state)
            _quotedStatus = try? container.decodeIfPresent(Status.Box.self, forKey: ._quotedStatus)
        }
    }

    public struct Card: Codable, Sendable, Hashable {
        public var url: String
        public var title: String
        public var description: String?
        public var providerName: String?
        /// The preview image and its size in pixels.
        public var image: String?
        public var width: Double?
        public var height: Double?
        public var imageDescription: String?
    }

    public struct FilterResult: Codable, Sendable, Hashable {
        public var filter: Filter

        public struct Filter: Codable, Sendable, Hashable {
            /// `warn`, `hide` or (4.4+) `blur`.
            public var filterAction: String
        }
    }

    public struct List: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
    }

    /// What `POST /api/v1/apps` returns: the app's registration on one
    /// instance.
    public struct Application: Codable, Sendable, Hashable {
        public var clientId: String
        public var clientSecret: String
    }

    /// What `POST /oauth/token` returns.
    public struct Token: Codable, Sendable, Hashable {
        public var accessToken: String
        public var tokenType: String
        public var scope: String
    }
}

extension Mastodon {
    /// Decodes API responses: snake_case keys, and ISO 8601 dates with or
    /// without fractional seconds (Mastodon sends milliseconds; some
    /// compatible servers don't).
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        return decoder
    }
}
