import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The platform's App Attest service: `DCAppAttestService` in the app, a
/// fake in tests. InfluxKit builds on Linux, which has no DeviceCheck, so
/// the app passes this in.
public protocol AppAttestService: Sendable {
    /// Whether this device and build can attest at all.
    var isSupported: Bool { get }
    /// A new key in the Secure Enclave, named by its key ID (base64).
    func generateKey() async throws -> String
    /// Apple's attestation of the key, over `clientDataHash`.
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    /// An assertion by the key over `clientDataHash`.
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// What an `AppAttestService` throws that the attestation acts on.
public enum AppAttestError: Error, Hashable, Sendable {
    /// The platform no longer has the key, as after a reinstall or a
    /// restore onto another device: a new one has to be registered.
    case invalidKey
}

/// Proves to the OAuth Worker that a request comes from a genuine Influx
/// install (ADR 0033). The install registers an App Attest key once, and
/// each request then carries an assertion by it over the request's exact
/// body, which names a fresh challenge.
///
/// Challenge, assertion and request run as one step, one at a time:
/// concurrent requests wait their turn, because assertions reaching the
/// Worker out of counter order are refused. One instance serves every
/// Worker host, which share one key store.
public actor CallerAttestation {
    /// The platform the Worker checks the key for.
    public enum Platform: String, Sendable {
        case ios
        case mac
    }

    /// The registered key's ID, base64.
    static let keyHeader = "X-Influx-Key"
    /// The assertion, base64, over SHA-256 of the exact body.
    static let assertionHeader = "X-Influx-Assertion"
    /// The registered key ID's entry in `keys`.
    static let keyAccount = "app-attest-key"

    public nonisolated let service: any AppAttestService
    let keys: any CredentialStore
    let http: any HTTPClient
    let sha256: @Sendable (Data) -> Data
    let platform: Platform
    let appID: String

    /// The registered key, once read from `keys`; nil inside when there is
    /// none.
    private var cachedKey: String??
    /// Set when this install couldn't register a key in this run. Until the
    /// next launch its requests go unattested, so a failing registration
    /// doesn't make a new key (which Apple counts) on every request.
    private var cannotRegister = false
    /// Set once the Worker refuses this build (403 `app_not_accepted`). No
    /// new key can fix that, so for the rest of this run every call fails
    /// at once, without asking Apple for a key or the Worker again.
    private var notAccepted = false
    /// Set once this run has made a key that isn't registered yet, so a
    /// throttled registration knows a retry would make a second one.
    private var madeUnregisteredKey = false
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// `keys` keeps the registered key ID, on this device only (the key
    /// itself never leaves it); `appID` is the app's bundle ID.
    public init(service: any AppAttestService, keys: any CredentialStore, http: any HTTPClient, crypto: OAuthCrypto, platform: Platform, appID: String) {
        self.service = service
        self.keys = keys
        self.http = http
        sha256 = crypto.sha256
        self.platform = platform
        self.appID = appID
    }

    /// POSTs the JSON `body` makes to `url`, attested where the platform
    /// can attest. `body` gets the challenge to name, or nil for a request
    /// that goes without attestation. Returns the Worker's answer, except
    /// for 403 `app_not_accepted`, which throws `BlueskyError.appNotAccepted`.
    ///
    /// A 401 `key_unknown` registers a new key and retries; a 401
    /// `attestation_required` retries once on the same key with a fresh
    /// challenge, and registers a new key only if that also fails. One call
    /// registers at most once. An install that can't register (the platform
    /// fails, or the Worker refuses the attestation for anything but
    /// policy) asks without attestation, and the Worker decides.
    public func send(to url: URL, body: @Sendable (_ challenge: String?) throws -> Data) async throws -> (Data, HTTPURLResponse) {
        guard service.isSupported else { return try await http.send(Self.request(url, try body(nil))) }
        await takeTurn()
        defer { endTurn() }
        try Task.checkCancellation()
        if notAccepted { throw BlueskyError.appNotAccepted }
        let origin = BlueskyOAuth.origin(url)
        var registered = false
        var retried = false
        while true {
            guard let key = try await key(origin: origin, registered: &registered) else {
                return try await http.send(Self.request(url, try body(nil)))
            }
            var request: URLRequest
            let assertion: Data
            do {
                let challenge = try await challenge(origin)
                request = Self.request(url, try body(challenge))
                assertion = try await service.generateAssertion(key, clientDataHash: sha256(request.httpBody ?? Data()))
            } catch AppAttestError.invalidKey {
                // The key is gone from this device: a new one, once.
                forgetKey()
                if registered { return try await http.send(Self.request(url, try body(nil))) }
                continue
            } catch let error as CannotAttest {
                AuthLog.cannotAttest(error.reason)
                return try await http.send(Self.request(url, try body(nil)))
            } catch let error where Self.isServiceFailure(error) {
                AuthLog.cannotAttest("assertion: \(error)")
                return try await http.send(Self.request(url, try body(nil)))
            }
            request.setValue(key, forHTTPHeaderField: Self.keyHeader)
            request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: Self.assertionHeader)
            let (data, response) = try await http.send(request)
            switch Self.refusal(data, response) {
            case "key_unknown" where response.statusCode == 401 && !registered:
                forgetKey()
            case "attestation_required" where response.statusCode == 401 && !retried:
                retried = true
            case "attestation_required" where response.statusCode == 401 && !registered:
                forgetKey()
            case "app_not_accepted" where response.statusCode == 403:
                // Only another build can fix this: no retry, no new key.
                notAccepted = true
                throw BlueskyError.appNotAccepted
            default:
                return (data, response)
            }
        }
    }

    // MARK: The key

    /// The registered key, registering one if there is none and this call
    /// hasn't registered yet; nil when the request has to go unattested.
    private func key(origin: URL, registered: inout Bool) async throws -> String? {
        if let key = storedKey() { return key }
        guard !registered, !cannotRegister else { return nil }
        registered = true
        do {
            let key = try await register(origin: origin)
            cachedKey = .some(key)
            // Kept in memory for this run even if the keychain refuses it.
            try? keys.setData(Data(key.utf8), for: Self.keyAccount)
            return key
        } catch {
            // Once a key is made, any failure to register it (throttled,
            // the Worker down, the network gone) stops registering for this
            // run: a new key each request would spend Apple's allowance.
            // Before a key is made, the next request may simply try again.
            if madeUnregisteredKey { cannotRegister = true }
            switch error {
            case BlueskyError.appNotAccepted:
                notAccepted = true
                throw error
            case let error as CannotAttest:
                // The Worker's answer: retried later unless a key was made.
                AuthLog.cannotAttest(error.reason)
            case _ where Self.isServiceFailure(error):
                // Apple's service failed: this device can't attest now, and
                // asking again each request could make keys.
                AuthLog.cannotAttest("registration: \(error)")
                cannotRegister = true
            default:
                throw error
            }
        }
        return nil
    }

    private func storedKey() -> String? {
        if let cachedKey { return cachedKey }
        let stored = (try? keys.data(for: Self.keyAccount)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
        cachedKey = .some(stored)
        return stored
    }

    private func forgetKey() {
        cachedKey = .some(nil)
        try? keys.deleteData(for: Self.keyAccount)
    }

    /// Makes a key, has Apple attest it over a fresh challenge, and
    /// registers it with the Worker.
    private func register(origin: URL) async throws -> String {
        struct Body: Encodable {
            var platform: String
            var appId: String
            var keyId: String
            var attestation: String
            var challenge: String
        }
        let challenge = try await challenge(origin)
        let key = try await service.generateKey()
        madeUnregisteredKey = true
        let attestation = try await service.attestKey(key, clientDataHash: sha256(Data(challenge.utf8)))
        let body = try JSONEncoder().encode(Body(
            platform: platform.rawValue, appId: appID, keyId: key, attestation: attestation.base64EncodedString(), challenge: challenge
        ))
        let (data, response) = try await http.send(Self.request(origin.appending(path: "oauth/register"), body))
        switch response.statusCode {
        case 201:
            madeUnregisteredKey = false
            return key
        case 403 where Self.refusal(data, response) == "app_not_accepted":
            throw BlueskyError.appNotAccepted
        case 429, 503:
            throw BlueskyError.rateLimited(until: DPoPRequest.rateLimitReset(response))
        default:
            throw CannotAttest(reason: "registration: HTTP \(response.statusCode) \(Self.refusal(data, response) ?? "")")
        }
    }

    /// A fresh single-use challenge from the Worker.
    private func challenge(_ origin: URL) async throws -> String {
        struct Reply: Decodable { var challenge: String }
        let (data, response) = try await http.send(Self.request(origin.appending(path: "oauth/challenge"), nil))
        if response.statusCode == 429 || response.statusCode == 503 {
            throw BlueskyError.rateLimited(until: DPoPRequest.rateLimitReset(response))
        }
        guard response.statusCode == 200, let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw CannotAttest(reason: "challenge: HTTP \(response.statusCode)")
        }
        return reply.challenge
    }

    // MARK: Turns

    /// Waits until no other call is between its challenge and its answer.
    private func takeTurn() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the turn to the next waiting call, if any.
    private func endTurn() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: Helpers

    /// Why this install can't attest a request, which then goes without.
    struct CannotAttest: Error {
        var reason: String
    }

    /// A failure of the platform's App Attest service, as opposed to one
    /// that ends the request: cancellation, being offline, or an answer
    /// from the Worker.
    private static func isServiceFailure(_ error: any Error) -> Bool {
        !(error is CancellationError) && !(error is ConnectorError) && !(error is BlueskyError)
    }

    private static func request(_ url: URL, _ body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The Worker's `error` code in a 401 or 403.
    private static func refusal(_ data: Data, _ response: HTTPURLResponse) -> String? {
        struct Body: Decodable { var error: String }
        guard response.statusCode == 401 || response.statusCode == 403 else { return nil }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error
    }
}
