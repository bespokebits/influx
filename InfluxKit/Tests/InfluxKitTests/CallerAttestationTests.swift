import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

// Caller attestation (ADR 0033): the app registers an App Attest key once,
// then signs every request to the signing service with it, one at a time.

private let signer = URL(string: "https://signer.example.com/oauth/assertion")!
private let appID = "com.example.reader"

/// An App Attest service that makes `key-1`, `key-2`… and "signs" by naming
/// the key and the hash, recording every call.
private final class FakeAppAttest: AppAttestService, @unchecked Sendable {
    struct Call: Hashable {
        var kind: String
        var keyID: String
        var hash: Data
    }

    let isSupported: Bool
    /// What making a key, or an assertion, throws every time, if anything.
    let keyFailure: AppAttestError?
    let assertionFailure: AppAttestError?
    private let lock = NSLock()
    private var made = 0
    private var _calls: [Call] = []
    private var _invalid: Set<String> = []

    init(isSupported: Bool = true, keyFailure: AppAttestError? = nil, assertionFailure: AppAttestError? = nil) {
        self.isSupported = isSupported
        self.keyFailure = keyFailure
        self.assertionFailure = assertionFailure
    }

    var calls: [Call] { lock.withLock { _calls } }
    var keysMade: Int { lock.withLock { made } }

    /// Keys the platform has lost, as after a reinstall.
    func lose(_ keyID: String) {
        _ = lock.withLock { _invalid.insert(keyID) }
    }

    func generateKey() async throws -> String {
        if let keyFailure { throw keyFailure }
        return lock.withLock {
            made += 1
            return "key-\(made)"
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { _calls.append(Call(kind: "attest", keyID: keyID, hash: clientDataHash)) }
        return Data("attestation:\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        if let assertionFailure { throw assertionFailure }
        return try lock.withLock {
            if _invalid.contains(keyID) { throw AppAttestError.invalidKey }
            _calls.append(Call(kind: "assert", keyID: keyID, hash: clientDataHash))
            return Data("assertion:\(keyID):\(_calls.count)".utf8)
        }
    }
}

/// The Worker's three routes, answering assertions from a script and then
/// with a signed assertion.
private final class FakeWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var challenges = 0
    private var assertionAnswers: [FakeHTTPClient.Response]
    private var registerAnswers: [FakeHTTPClient.Response]
    private var challengeAnswers: [FakeHTTPClient.Response]
    /// How many registrations get no answer at all, as if offline.
    private var unreachableRegistrations: Int
    let http = FakeHTTPClient { _ in .init(status: 404) }

    init(
        assertions: [FakeHTTPClient.Response] = [], registrations: [FakeHTTPClient.Response] = [],
        challenges: [FakeHTTPClient.Response] = [], unreachableRegistrations: Int = 0
    ) {
        assertionAnswers = assertions
        registerAnswers = registrations
        challengeAnswers = challenges
        self.unreachableRegistrations = unreachableRegistrations
        http.respond { [unowned self] request in try self.answer(request) }
    }

    static func refusal(_ status: Int, _ code: String) -> FakeHTTPClient.Response {
        .init(status: status, body: try! JSONSerialization.data(withJSONObject: ["error": code]))
    }

    private func answer(_ request: URLRequest) throws -> FakeHTTPClient.Response {
        try lock.withLock {
            switch request.url?.path {
            case "/oauth/challenge":
                if !challengeAnswers.isEmpty { return challengeAnswers.removeFirst() }
                challenges += 1
                return .init(body: try! JSONSerialization.data(withJSONObject: ["challenge": "challenge-\(challenges)"]))
            case "/oauth/register":
                if unreachableRegistrations > 0 {
                    unreachableRegistrations -= 1
                    throw ConnectorError.offline
                }
                if !registerAnswers.isEmpty { return registerAnswers.removeFirst() }
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                return .init(status: 201, body: try! JSONSerialization.data(withJSONObject: ["keyId": body["keyId"]!]))
            case "/oauth/assertion":
                if !assertionAnswers.isEmpty { return assertionAnswers.removeFirst() }
                return .init(body: try! JSONSerialization.data(withJSONObject: ["client_assertion": "jwt", "kid": "client-key"]))
            default:
                return .init(status: 404)
            }
        }
    }
}

/// Why each request went without attestation, nil for one that didn't say.
private func reasons(_ http: FakeHTTPClient) -> [String?] {
    http.requests.filter { $0.url?.path == "/oauth/assertion" }.map { $0.value(forHTTPHeaderField: "X-Influx-Unattested") }
}

private func paths(_ http: FakeHTTPClient) -> [String] {
    http.requests.compactMap { $0.url?.path.replacingOccurrences(of: "/oauth/", with: "") }
}

private func json(_ request: URLRequest) throws -> [String: String] {
    let body = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
}

private func storedKey(_ keys: InMemoryCredentialStore) throws -> String? {
    try keys.data(for: CallerAttestation.keyAccount).map { String(decoding: $0, as: UTF8.self) }
}

private func keysHolding(_ keyID: String) throws -> InMemoryCredentialStore {
    let keys = InMemoryCredentialStore()
    try keys.setData(Data(keyID.utf8), for: CallerAttestation.keyAccount)
    return keys
}

private func service(
    _ http: any HTTPClient, _ attest: FakeAppAttest, keys: InMemoryCredentialStore = InMemoryCredentialStore(), platform: CallerAttestation.Platform = .ios
) -> ClientAssertionService {
    let attestation = CallerAttestation(service: attest, keys: keys, http: http, crypto: .fake(), platform: platform, appID: appID)
    return ClientAssertionService(url: signer, http: http, attestation: attestation)
}

/// `OAuthCrypto.fake()`'s SHA-256.
private func fakeHash(_ data: Data) -> Data {
    Data("sha256:".utf8) + data
}

@Suite struct CallerAttestationTests {
    @Test func theFirstRequestRegistersAKeyThenSignsTheRequest() async throws {
        let worker = FakeWorker()
        let attest = FakeAppAttest()
        let keys = InMemoryCredentialStore()
        let assertion = try await service(worker.http, attest, keys: keys).assertion(for: "https://auth.example.com", keyID: nil)
        #expect(assertion == ClientAssertion(jwt: "jwt", keyID: "client-key"))
        #expect(paths(worker.http) == ["challenge", "register", "challenge", "assertion"])
        #expect(try storedKey(keys) == "key-1")

        // The key is attested over SHA-256 of the challenge string.
        let register = worker.http.requests[1]
        #expect(register.httpMethod == "POST")
        #expect(try json(register) == [
            "platform": "ios", "appId": appID, "keyId": "key-1",
            "attestation": Data("attestation:key-1".utf8).base64EncodedString(), "challenge": "challenge-1",
        ])
        #expect(attest.calls.first == .init(kind: "attest", keyID: "key-1", hash: fakeHash(Data("challenge-1".utf8))))

        // The request names a fresh challenge and carries the key and an
        // assertion over exactly the bytes sent.
        let request = worker.http.requests[3]
        let body = try #require(request.httpBody)
        #expect(try json(request) == ["aud": "https://auth.example.com", "challenge": "challenge-2"])
        #expect(request.value(forHTTPHeaderField: "X-Influx-Key") == "key-1")
        let signed = try #require(attest.calls.last)
        #expect(signed == .init(kind: "assert", keyID: "key-1", hash: fakeHash(body)))
        #expect(request.value(forHTTPHeaderField: "X-Influx-Assertion") == Data("assertion:key-1:2".utf8).base64EncodedString())
    }

    @Test func aMacRegistersAsAMac() async throws {
        let worker = FakeWorker()
        _ = try await service(worker.http, FakeAppAttest(), platform: .mac).assertion(for: "https://auth.example.com", keyID: nil)
        #expect(try json(worker.http.requests[1])["platform"] == "mac")
    }

    @Test func laterRequestsUseTheRegisteredKeyWithAFreshChallengeEach() async throws {
        let worker = FakeWorker()
        let attest = FakeAppAttest()
        let keys = InMemoryCredentialStore()
        let signing = service(worker.http, attest, keys: keys)
        _ = try await signing.assertion(for: "https://auth.example.com", keyID: nil)
        _ = try await signing.assertion(for: "https://auth.example.com", keyID: "client-key")
        #expect(paths(worker.http) == ["challenge", "register", "challenge", "assertion", "challenge", "assertion"])
        #expect(try json(worker.http.requests[5]) == ["aud": "https://auth.example.com", "kid": "client-key", "challenge": "challenge-3"])

        // The next launch finds the key where it was kept.
        let relaunched = service(worker.http, attest, keys: keys)
        _ = try await relaunched.assertion(for: "https://auth.example.com", keyID: nil)
        #expect(paths(worker.http).suffix(2) == ["challenge", "assertion"])
        #expect(worker.http.requests.last?.value(forHTTPHeaderField: "X-Influx-Key") == "key-1")
        #expect(attest.keysMade == 1)
    }

    @Test func anUnknownKeyIsReplacedOnceAndTheRequestRetried() async throws {
        let worker = FakeWorker(assertions: [FakeWorker.refusal(401, "key_unknown")])
        let attest = FakeAppAttest()
        let keys = try keysHolding("forgotten")
        _ = try await service(worker.http, attest, keys: keys).assertion(for: "https://auth.example.com", keyID: nil)
        #expect(paths(worker.http) == ["challenge", "assertion", "challenge", "register", "challenge", "assertion"])
        #expect(worker.http.requests[1].value(forHTTPHeaderField: "X-Influx-Key") == "forgotten")
        #expect(worker.http.requests[5].value(forHTTPHeaderField: "X-Influx-Key") == "key-1")
        #expect(try storedKey(keys) == "key-1")

        // A new key that is unknown too isn't replaced again in the same call.
        let again = FakeWorker(assertions: [FakeWorker.refusal(401, "key_unknown"), FakeWorker.refusal(401, "key_unknown")])
        await #expect(throws: BlueskyError.http(status: 401, error: "client assertion")) {
            try await service(again.http, FakeAppAttest(), keys: try keysHolding("forgotten")).assertion(for: "https://auth.example.com", keyID: nil)
        }
        #expect(paths(again.http) == ["challenge", "assertion", "challenge", "register", "challenge", "assertion"])
    }

    @Test func aRefusedAssertionIsRetriedOnTheSameKeyBeforeANewOne() async throws {
        let once = FakeWorker(assertions: [FakeWorker.refusal(401, "attestation_required")])
        let attest = FakeAppAttest()
        _ = try await service(once.http, attest, keys: try keysHolding("old")).assertion(for: "https://auth.example.com", keyID: nil)
        #expect(paths(once.http) == ["challenge", "assertion", "challenge", "assertion"])
        #expect(once.http.requests.compactMap { $0.value(forHTTPHeaderField: "X-Influx-Key") } == ["old", "old"])
        #expect(try json(once.http.requests[3])["challenge"] == "challenge-2")
        #expect(attest.keysMade == 0)

        // Refused twice: then, and only then, a new key.
        let twice = FakeWorker(assertions: [FakeWorker.refusal(401, "attestation_required"), FakeWorker.refusal(401, "attestation_required")])
        let keys = try keysHolding("old")
        _ = try await service(twice.http, FakeAppAttest(), keys: keys).assertion(for: "https://auth.example.com", keyID: nil)
        #expect(paths(twice.http) == ["challenge", "assertion", "challenge", "assertion", "challenge", "register", "challenge", "assertion"])
        #expect(twice.http.requests.compactMap { $0.value(forHTTPHeaderField: "X-Influx-Key") } == ["old", "old", "key-1"])
        #expect(try storedKey(keys) == "key-1")

        // Refused every time: one retry and one new key, then it gives up.
        let always = FakeWorker(assertions: Array(repeating: FakeWorker.refusal(401, "attestation_required"), count: 5))
        let tries = FakeAppAttest()
        await #expect(throws: BlueskyError.http(status: 401, error: "client assertion")) {
            try await service(always.http, tries, keys: try keysHolding("old")).assertion(for: "https://auth.example.com", keyID: nil)
        }
        #expect(paths(always.http).filter { $0 == "assertion" }.count == 3)
        #expect(tries.keysMade == 1)
    }

    @Test func aBuildTheWorkerDoesNotAcceptStopsAtOnce() async throws {
        let worker = FakeWorker(assertions: [FakeWorker.refusal(403, "app_not_accepted")])
        let attest = FakeAppAttest()
        let keys = try keysHolding("old")
        await #expect(throws: BlueskyError.appNotAccepted) {
            try await service(worker.http, attest, keys: keys).assertion(for: "https://auth.example.com", keyID: nil)
        }
        #expect(paths(worker.http) == ["challenge", "assertion"])
        #expect(attest.keysMade == 0)
        // A new key couldn't fix it, so the key is kept.
        #expect(try storedKey(keys) == "old")

        // Refused at registration: no request follows.
        let atRegistration = FakeWorker(registrations: [FakeWorker.refusal(403, "app_not_accepted")])
        let fresh = InMemoryCredentialStore()
        await #expect(throws: BlueskyError.appNotAccepted) {
            try await service(atRegistration.http, FakeAppAttest(), keys: fresh).assertion(for: "https://auth.example.com", keyID: nil)
        }
        #expect(paths(atRegistration.http) == ["challenge", "register"])
        #expect(try storedKey(fresh) == nil)
    }

    /// Once the Worker refuses the build, nothing in this run asks Apple
    /// for another key or the Worker again, whether it refused the
    /// registration or a request.
    @Test func aRefusedBuildMakesNoMoreKeysThisRun() async throws {
        let worker = FakeWorker(registrations: [FakeWorker.refusal(403, "app_not_accepted")])
        let attest = FakeAppAttest()
        let signer = service(worker.http, attest, keys: InMemoryCredentialStore())
        for _ in 0..<3 {
            await #expect(throws: BlueskyError.appNotAccepted) {
                try await signer.assertion(for: "https://auth.example.com", keyID: nil)
            }
        }
        #expect(attest.keysMade == 1)
        #expect(paths(worker.http) == ["challenge", "register"])

        let refusing = FakeWorker(assertions: [FakeWorker.refusal(403, "app_not_accepted")])
        let registered = service(refusing.http, FakeAppAttest(), keys: try keysHolding("old"))
        for _ in 0..<2 {
            await #expect(throws: BlueskyError.appNotAccepted) {
                try await registered.assertion(for: "https://auth.example.com", keyID: nil)
            }
        }
        #expect(paths(refusing.http) == ["challenge", "assertion"])
    }

    /// A registration the Worker throttles or can't take makes no second
    /// key in the same run: the next request goes without attestation.
    @Test func aThrottledRegistrationMakesNoMoreKeysThisRun() async throws {
        let worker = FakeWorker(registrations: [FakeWorker.refusal(429, "rate_limited")])
        let attest = FakeAppAttest()
        let signer = service(worker.http, attest, keys: InMemoryCredentialStore())
        await #expect(throws: (any Error).self) {
            try await signer.assertion(for: "https://auth.example.com", keyID: nil)
        }
        _ = try await signer.assertion(for: "https://auth.example.com", keyID: nil)
        #expect(attest.keysMade == 1)
        #expect(paths(worker.http) == ["challenge", "register", "assertion"])
        #expect(worker.http.requests.last?.value(forHTTPHeaderField: "X-Influx-Key") == nil)
    }

    /// Throttled before any key was made, a fresh install registers on its
    /// next request instead of going unattested for the rest of the run.
    @Test func aThrottledFirstChallengeLeavesRegistrationOpen() async throws {
        let worker = FakeWorker(challenges: [FakeWorker.refusal(429, "rate_limited")])
        let attest = FakeAppAttest()
        let signer = service(worker.http, attest, keys: InMemoryCredentialStore())
        await #expect(throws: (any Error).self) {
            try await signer.assertion(for: "https://auth.example.com", keyID: nil)
        }
        #expect(attest.keysMade == 0)
        _ = try await signer.assertion(for: "https://auth.example.com", keyID: nil)
        #expect(attest.keysMade == 1)
        #expect(paths(worker.http) == ["challenge", "challenge", "register", "challenge", "assertion"])
        #expect(worker.http.requests.last?.value(forHTTPHeaderField: "X-Influx-Key") == "key-1")
    }

    /// The Worker unreachable once the key was made: no second key in the
    /// same run.
    @Test func anUnreachableRegistrationMakesNoMoreKeysThisRun() async throws {
        let worker = FakeWorker(unreachableRegistrations: 1)
        let attest = FakeAppAttest()
        let signer = service(worker.http, attest, keys: InMemoryCredentialStore())
        await #expect(throws: ConnectorError.offline) {
            try await signer.assertion(for: "https://auth.example.com", keyID: nil)
        }
        _ = try await signer.assertion(for: "https://auth.example.com", keyID: nil)
        #expect(attest.keysMade == 1)
        #expect(paths(worker.http) == ["challenge", "register", "assertion"])
        #expect(worker.http.requests.last?.value(forHTTPHeaderField: "X-Influx-Key") == nil)
    }

    /// A challenge that fails before any key is made (here a 500) leaves
    /// registration open: the request goes without attestation, and the
    /// next one registers.
    @Test func aFailedFirstChallengeLeavesRegistrationOpen() async throws {
        let worker = FakeWorker(challenges: [.init(status: 500)])
        let attest = FakeAppAttest()
        let signer = service(worker.http, attest, keys: InMemoryCredentialStore())
        _ = try await signer.assertion(for: "https://auth.example.com", keyID: nil)
        #expect(attest.keysMade == 0)
        _ = try await signer.assertion(for: "https://auth.example.com", keyID: nil)
        #expect(attest.keysMade == 1)
        #expect(paths(worker.http) == ["challenge", "assertion", "challenge", "register", "challenge", "assertion"])
        #expect(worker.http.requests.last?.value(forHTTPHeaderField: "X-Influx-Key") == "key-1")
        #expect(reasons(worker.http) == ["challenge-refused", nil])
    }

    @Test func aKeyThePlatformLostIsReplaced() async throws {
        let worker = FakeWorker()
        let attest = FakeAppAttest()
        attest.lose("restored")
        let keys = try keysHolding("restored")
        _ = try await service(worker.http, attest, keys: keys).assertion(for: "https://auth.example.com", keyID: nil)
        #expect(paths(worker.http) == ["challenge", "challenge", "register", "challenge", "assertion"])
        #expect(worker.http.requests.last?.value(forHTTPHeaderField: "X-Influx-Key") == "key-1")
        #expect(try storedKey(keys) == "key-1")
    }

    @Test func anInstallThatCannotRegisterAsksUnattestedAndDoesNotKeepTrying() async throws {
        let worker = FakeWorker(registrations: [FakeWorker.refusal(401, "attestation_invalid")])
        let attest = FakeAppAttest()
        let keys = InMemoryCredentialStore()
        let signing = service(worker.http, attest, keys: keys)
        let assertion = try await signing.assertion(for: "https://auth.example.com", keyID: nil)
        #expect(assertion.jwt == "jwt")
        #expect(paths(worker.http) == ["challenge", "register", "assertion"])
        let request = try #require(worker.http.requests.last)
        #expect(request.value(forHTTPHeaderField: "X-Influx-Key") == nil)
        #expect(try json(request) == ["aud": "https://auth.example.com"])

        // Not again in this run: each try would make a key Apple counts.
        _ = try await signing.assertion(for: "https://auth.example.com", keyID: nil)
        #expect(paths(worker.http).suffix(1) == ["assertion"])
        #expect(reasons(worker.http) == ["register-refused", "register-refused"])
        #expect(attest.keysMade == 1)
        #expect(try storedKey(keys) == nil)
    }

    @Test func whereThePlatformCannotAttestRequestsGoAsBefore() async throws {
        let worker = FakeWorker()
        let attest = FakeAppAttest(isSupported: false)
        _ = try await service(worker.http, attest).assertion(for: "https://auth.example.com", keyID: "client-key")
        #expect(paths(worker.http) == ["assertion"])
        let request = try #require(worker.http.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Influx-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Influx-Assertion") == nil)
        #expect(try json(request) == ["aud": "https://auth.example.com", "kid": "client-key"])
        #expect(attest.keysMade == 0)
        #expect(reasons(worker.http) == ["unsupported"])
    }

    /// A platform that can't make an assertion with the registered key:
    /// the request goes without attestation, naming the step and the
    /// platform's error code, so the Worker's counts show it.
    @Test func aFailedAssertionSaysWhyTheRequestIsUnattested() async throws {
        let worker = FakeWorker()
        let attest = FakeAppAttest(assertionFailure: .failed(code: 2))
        let signing = service(worker.http, attest, keys: try keysHolding("key"))
        for _ in 0..<2 {
            _ = try await signing.assertion(for: "https://auth.example.com", keyID: nil)
        }
        #expect(paths(worker.http) == ["challenge", "assertion", "challenge", "assertion"])
        #expect(worker.http.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Influx-Key") == nil })
        #expect(reasons(worker.http) == ["assert-failed-dc2", "assert-failed-dc2"])
    }

    /// A key the platform can't make stops registering for the run, and
    /// every request in it says why. A code too large for the fixed set
    /// reads as "other".
    @Test func aKeyThePlatformCannotMakeIsNamedForTheRestOfTheRun() async throws {
        let worker = FakeWorker()
        let signing = service(worker.http, FakeAppAttest(keyFailure: .failed(code: 1)))
        for _ in 0..<2 {
            _ = try await signing.assertion(for: "https://auth.example.com", keyID: nil)
        }
        #expect(paths(worker.http) == ["challenge", "assertion", "assertion"])
        #expect(reasons(worker.http) == ["key-failed-dc1", "key-failed-dc1"])
        #expect(CallerAttestation.reason("attest", AppAttestError.failed(code: 42)) == "attest-failed-other")
        #expect(CallerAttestation.reason("attest", AppAttestError.invalidKey) == "attest-failed-other")
    }

    @Test func anAttestedRequestNamesNoReason() async throws {
        let worker = FakeWorker()
        _ = try await service(worker.http, FakeAppAttest(), keys: try keysHolding("key")).assertion(for: "https://auth.example.com", keyID: nil)
        #expect(reasons(worker.http) == [nil])
    }

    @Test func concurrentRequestsTakeTurns() async throws {
        let worker = FakeWorker()
        let gate = Gate()
        let http = GatedClient(inner: worker.http, gate: gate)
        let attest = FakeAppAttest()
        let signing = service(http, attest, keys: try keysHolding("key"))

        let first = Task { try await signing.assertion(for: "https://auth.example.com", keyID: nil) }
        while !gate.arrived { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { try await signing.assertion(for: "https://auth.example.com", keyID: nil) }
        // The second waits for the first's answer before it even asks for
        // a challenge.
        try await Task.sleep(for: .milliseconds(200))
        #expect(paths(worker.http) == ["challenge"])

        gate.open()
        _ = try await first.value
        _ = try await second.value
        #expect(paths(worker.http) == ["challenge", "assertion", "challenge", "assertion"])
        // Assertions reach the Worker in the order they were made.
        let sent = worker.http.requests.compactMap { $0.value(forHTTPHeaderField: "X-Influx-Assertion") }
        #expect(sent == [Data("assertion:key:1".utf8).base64EncodedString(), Data("assertion:key:2".utf8).base64EncodedString()])
    }
}

/// Holds the first assertion request until opened.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var _arrived = false
    private var waiter: CheckedContinuation<Void, Never>?

    var arrived: Bool { lock.withLock { _arrived } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if opened { return true }
                _arrived = true
                waiter = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiter = lock.withLock {
            opened = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }
}

private struct GatedClient: HTTPClient {
    let inner: FakeHTTPClient
    let gate: Gate

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/oauth/assertion" { await gate.wait() }
        return try await inner.send(request)
    }

    func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }

    func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }
}
