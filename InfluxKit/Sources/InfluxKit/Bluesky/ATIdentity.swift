import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What went wrong talking to Bluesky.
public enum BlueskyError: Error, Hashable, Sendable {
    /// The handle or DID doesn't resolve to an account with a PDS.
    case identityNotFound(String)
    /// A server's metadata breaks the AT Protocol OAuth profile.
    case badMetadata(String)
    /// The authorization server refused the request (an OAuth `error` code).
    case oauth(String)
    /// The sign-in callback doesn't match the request that started it.
    case callbackMismatch(String)
    /// The browser signed in to another account than the one asked for
    /// (its DID). Its grant has been revoked.
    case differentAccount(String)
    /// The account's session has ended; it needs signing in again.
    case signInRequired
    /// Too many requests; try again after the date, if the server gave one.
    case rateLimited(until: Date?)
    /// The signing service doesn't accept this build of Influx (ADR 0033):
    /// it is too old, or isn't one it attests. Only another build fixes
    /// that, so nothing retries it.
    case appNotAccepted
    /// Any other unexpected HTTP status.
    case http(status: Int, error: String?)
}

/// An account's identity: its DID, the handle it claims, and its PDS.
public struct ATIdentity: Sendable, Hashable, Codable {
    public var did: String
    /// Nil when the DID document names no handle that points back at it.
    public var handle: String?
    public var pds: URL
}

/// Resolves handles and DIDs (atproto.com/specs/handle, /specs/did).
struct ATIdentityResolver: Sendable {
    let http: any HTTPClient
    /// Resolves handles whose domain can't be reached over HTTPS (DNS TXT
    /// handles), and is the PLC directory's neighbour for did:plc.
    var appView = URL(string: "https://public.api.bsky.app")!
    var plcDirectory = URL(string: "https://plc.directory")!

    /// A handle (with or without "@") or a DID.
    func resolve(_ input: String) async throws -> ATIdentity {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("did:") {
            return try await identity(did: trimmed, claimedHandle: nil)
        }
        let handle = Self.normalizedHandle(trimmed)
        let did = try await resolveHandle(handle)
        return try await identity(did: did, claimedHandle: handle)
    }

    static func normalizedHandle(_ input: String) -> String {
        var handle = input.lowercased()
        if handle.hasPrefix("@") { handle.removeFirst() }
        return handle
    }

    func resolveHandle(_ handle: String) async throws -> String {
        if let url = URL(string: "https://\(handle)/.well-known/atproto-did"),
           let result = try? await http.send(URLRequest(url: url)),
           result.1.statusCode == 200,
           let did = String(data: result.0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           did.hasPrefix("did:") {
            return did
        }
        var parts = URLComponents(url: appView.appending(path: "xrpc/com.atproto.identity.resolveHandle"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "handle", value: handle)]
        let (data, response) = try await http.send(URLRequest(url: parts.url!))
        guard response.statusCode == 200, let body = try? JSONDecoder().decode([String: String].self, from: data), let did = body["did"] else {
            throw BlueskyError.identityNotFound(handle)
        }
        return did
    }

    /// The DID's document, checked: its PDS, and its handle if the handle
    /// points back at the same DID.
    func identity(did: String, claimedHandle: String?) async throws -> ATIdentity {
        let document = try await didDocument(did)
        guard document.id == did, let pds = document.pdsEndpoint else {
            throw BlueskyError.identityNotFound(did)
        }
        var handle = document.handle
        if let claimedHandle {
            // Bidirectional: the handle named the DID, and the DID names it
            // back. Otherwise anyone's handle could send a sign-in to
            // someone else's account.
            guard handle == claimedHandle else { throw BlueskyError.identityNotFound(claimedHandle) }
        } else if let named = handle, (try? await resolveHandle(named)) != did {
            handle = nil
        }
        return ATIdentity(did: did, handle: handle, pds: pds)
    }

    func didDocument(_ did: String) async throws -> DIDDocument {
        let url: URL?
        if did.hasPrefix("did:plc:") {
            url = plcDirectory.appending(path: did)
        } else if did.hasPrefix("did:web:") {
            url = URL(string: "https://\(did.dropFirst("did:web:".count))/.well-known/did.json")
        } else {
            url = nil
        }
        guard let url else { throw BlueskyError.identityNotFound(did) }
        let (data, response) = try await http.send(URLRequest(url: url))
        guard response.statusCode == 200, let document = try? JSONDecoder().decode(DIDDocument.self, from: data) else {
            throw BlueskyError.identityNotFound(did)
        }
        return document
    }
}

struct DIDDocument: Decodable, Sendable {
    struct Service: Decodable, Sendable {
        var id: String
        var type: String
        var serviceEndpoint: String?

        enum CodingKeys: String, CodingKey { case id, type, serviceEndpoint }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            // Other services may use an object or a list here.
            serviceEndpoint = try? container.decodeIfPresent(String.self, forKey: .serviceEndpoint)
        }
    }

    var id: String
    var alsoKnownAs: [String]?
    var service: [Service]?

    var pdsEndpoint: URL? {
        guard let service = service?.first(where: {
            ($0.id == "#atproto_pds" || $0.id == "\(id)#atproto_pds") && $0.type == "AtprotoPersonalDataServer"
        }), let endpoint = service.serviceEndpoint, let url = URL(string: endpoint), url.scheme == "https" else {
            return nil
        }
        return url
    }

    /// The first `at://` alias, which is the handle the account claims.
    var handle: String? {
        alsoKnownAs?.first { $0.hasPrefix("at://") }.map { String($0.dropFirst("at://".count)).lowercased() }
    }
}
