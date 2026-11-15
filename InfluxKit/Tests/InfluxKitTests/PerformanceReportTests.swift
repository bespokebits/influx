import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

// Field performance reports (ADR 0034): the report the Worker takes, fitted
// from MetricKit's figures, and the reporter that sends them attested and
// keeps the ones not yet sent.

private let endpoint = URL(string: "https://perf.example.com/perf/report")!

private let report = PerformanceReport(
    platform: .ios, build: "42", os: "27.2", device: "iPhone16,2",
    periodStart: Date(timeIntervalSince1970: 1_794_441_600), periodEnd: Date(timeIntervalSince1970: 1_794_528_000),
    scrollHitchMsPerS: 1.5,
    launch: [.init(startMs: 200, endMs: 210, count: 3)], resume: nil
)

/// An App Attest service that makes `key-1` and "signs" by naming the key.
private final class FakeAppAttest: AppAttestService, @unchecked Sendable {
    let isSupported: Bool
    private let lock = NSLock()
    private var assertions = 0

    init(isSupported: Bool = true) {
        self.isSupported = isSupported
    }

    func generateKey() async throws -> String { "key-1" }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        Data("attestation:\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock {
            assertions += 1
            return Data("assertion:\(keyID):\(assertions)".utf8)
        }
    }
}

/// The Worker's challenge, register and report routes, answering reports
/// from a script and then with 204.
private final class FakeWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var challenges = 0
    private var reportAnswers: [FakeHTTPClient.Response]
    let http = FakeHTTPClient { _ in .init(status: 404) }

    init(reports: [FakeHTTPClient.Response] = []) {
        reportAnswers = reports
        http.respond { [unowned self] request in self.answer(request) }
    }

    /// The reports the Worker was sent, in order.
    var reportsSent: [URLRequest] { http.requests.filter { $0.url?.path == "/perf/report" } }

    private func answer(_ request: URLRequest) -> FakeHTTPClient.Response {
        lock.withLock {
            switch request.url?.path {
            case "/oauth/challenge":
                challenges += 1
                return .init(body: try! JSONSerialization.data(withJSONObject: ["challenge": "challenge-\(challenges)"]))
            case "/oauth/register":
                return .init(status: 201, body: try! JSONSerialization.data(withJSONObject: ["keyId": "key-1"]))
            case "/perf/report":
                return reportAnswers.isEmpty ? .init(status: 204) : reportAnswers.removeFirst()
            default:
                return .init(status: 404)
            }
        }
    }
}

/// A file in a folder of its own, under `TMPDIR` (which a sandboxed run sets) when there is one.
private func temporaryFile() -> URL {
    let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    return base.appending(path: "perf-\(UUID().uuidString)/PerformanceReports.json")
}

private func reporter(_ worker: FakeWorker, file: URL, attest: FakeAppAttest = FakeAppAttest()) -> PerformanceReporter {
    let attestation = CallerAttestation(
        service: attest, keys: InMemoryCredentialStore(), http: worker.http, crypto: .fake(), platform: .ios, appID: "com.example.reader"
    )
    return PerformanceReporter(attestation: attestation, file: file, endpoint: endpoint)
}

private func fileReports(_ file: URL) throws -> [PerformanceReport] {
    try JSONDecoder().decode([PerformanceReport].self, from: Data(contentsOf: file))
}

@Suite struct PerformanceReportTests {
    // MARK: The report

    @Test func itEncodesToExactlyTheWorkersSchema() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "platform", "build", "os", "device", "periodStart", "periodEnd", "scrollHitchMsPerS", "launch"])
        // A UUID in upper case, as the Worker checks it.
        #expect(object["id"] as? String == report.id.uuidString)
        #expect(report.id.uuidString == report.id.uuidString.uppercased())
        #expect(object["platform"] as? String == "ios")
        #expect(object["periodStart"] as? String == "2026-11-12T00:00:00Z")
        #expect(object["periodEnd"] as? String == "2026-11-13T00:00:00Z")
        #expect(object["scrollHitchMsPerS"] as? Double == 1.5)
        #expect(object["launch"] as? [[String: Int]] == [["startMs": 200, "endMs": 210, "count": 3]])

        // Nothing measured is sent as null, not left out; a resume is sent when there is one.
        var quiet = report
        quiet.scrollHitchMsPerS = nil
        quiet.resume = [.init(startMs: 0, endMs: 10, count: 1)]
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(quiet)) as? [String: Any])
        #expect(json["scrollHitchMsPerS"] is NSNull)
        #expect(json["resume"] as? [[String: Int]] == [["startMs": 0, "endMs": 10, "count": 1]])
        // And it reads back as it was.
        #expect(try JSONDecoder().decode(PerformanceReport.self, from: JSONEncoder().encode(quiet)) == quiet)

        // Grant counts are sent, every field of both kinds, when there are any.
        var counted = report
        counted.sammyMedia = .init(avatar: .init(grants: 40, grantsRateLimited: 1, heldBack: 3, deferred: 2),
                                   attachment: .init(grants: 9, bytesRateLimited: 1))
        let withMedia = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(counted)) as? [String: Any])
        let media = try #require(withMedia["sammyMedia"] as? [String: Any])
        #expect(Set(media.keys) == ["avatar", "attachment", "timeToImage"])
        #expect(media["avatar"] as? [String: Int] == ["grants": 40, "grantsRateLimited": 1, "bytesRateLimited": 0, "heldBack": 3, "deferred": 2,
                                                     "direct": 0, "fallbacks": 0])
        #expect(media["attachment"] as? [String: Int] == ["grants": 9, "grantsRateLimited": 0, "bytesRateLimited": 1, "heldBack": 0,
                                                         "deferred": 0, "direct": 0, "fallbacks": 0])
        // Since ADR 0040: one count per time-to-image bucket, each way.
        #expect(media["timeToImage"] as? [String: [Int]] == ["direct": [0, 0, 0, 0, 0, 0, 0], "grant": [0, 0, 0, 0, 0, 0, 0]])
        #expect(try JSONDecoder().decode(PerformanceReport.self, from: JSONEncoder().encode(counted)) == counted)
        // A report kept by a build before them reads as having no direct counts or times.
        let older = Data(#"{"avatar":{"grants":1,"grantsRateLimited":0,"bytesRateLimited":0,"heldBack":0,"deferred":0},"attachment":{"grants":2,"grantsRateLimited":0,"bytesRateLimited":0,"heldBack":0,"deferred":0}}"#.utf8)
        #expect(try JSONDecoder().decode(PerformanceReport.SammyMedia.self, from: older)
            == .init(avatar: .init(grants: 1), attachment: .init(grants: 2)))
    }

    // MARK: Grant counts

    @Test func grantCountsAddUpPerKindAndStartAgainOnceTaken() {
        let tally = SammyMediaTally()
        #expect(tally.take() == nil)
        tally.record(.grants, .avatar)
        tally.record(.grants, .avatar)
        tally.record(.grantsRateLimited, .avatar)
        tally.record(.heldBack, .attachment)
        #expect(tally.take() == .init(avatar: .init(grants: 2, grantsRateLimited: 1), attachment: .init(heldBack: 1)))
        // Nothing since: nothing to send.
        #expect(tally.take() == nil)
    }

    @Test func directLoadsFallbacksAndTimesToImageAreCounted() {
        let tally = SammyMediaTally()
        tally.record(.direct, .avatar)
        tally.record(.direct, .attachment)
        tally.record(.fallback, .attachment)
        // Each time in its bucket: ≤100, ≤250, ≤500, ≤1000, ≤2500, ≤5000 ms, and the rest.
        for milliseconds in [0, 100, 101, 250, 900, 2500, 2501, 5000, 5001, 60_000] {
            tally.time(.direct, .milliseconds(milliseconds))
        }
        tally.time(.grant, .milliseconds(700))
        #expect(tally.take() == .init(avatar: .init(direct: 1), attachment: .init(direct: 1, fallbacks: 1),
                                      timeToImage: .init(direct: [2, 2, 0, 1, 1, 2, 2], grant: [0, 0, 0, 1, 0, 0, 0])))
        #expect(tally.take() == nil)
    }

    @Test func grantCountsOfAnEarlierRunOfTheSameBuildAreKept() throws {
        let file = temporaryFile().deletingLastPathComponent().appending(path: "SammyMediaTally.json")
        let first = SammyMediaTally()
        first.keep(in: file, build: "42")
        first.record(.grants, .attachment)
        // Kept once: a second call adds nothing again.
        first.keep(in: file, build: "42")
        #expect(first.counts.attachment.grants == 1)
        first.save()

        // The next run of the build adds them to its own.
        let next = SammyMediaTally()
        next.record(.deferred, .avatar)
        next.keep(in: file, build: "42")
        #expect(next.counts == .init(avatar: .init(deferred: 1), attachment: .init(grants: 1)))
        // Taken counts leave the file too.
        #expect(next.take() == .init(avatar: .init(deferred: 1), attachment: .init(grants: 1)))
        let third = SammyMediaTally()
        third.keep(in: file, build: "42")
        #expect(third.counts == .init())

        // Another build's counts are dropped: a report never spans an update.
        third.record(.grants, .avatar)
        third.save()
        let updated = SammyMediaTally()
        updated.keep(in: file, build: "43")
        #expect(updated.take() == nil)
    }

    @Test func metricKitsFiguresAreFittedToTheWorkersTerms() throws {
        let measured = PerformanceReport.Measured(
            platform: .mac, build: "0.1.7", os: "macOS 27.2 (26C101)", device: "Mac 15,6!",
            periodStart: 1_794_441_600.4, periodEnd: 1_794_528_000.2,
            scrollHitch: .init(value: 2.25, unit: "ms per s"),
            launch: [
                .init(startMs: 310.4, endMs: 320.2, count: 2),
                .init(startMs: 100, endMs: 110, count: 0),
                .init(startMs: 0, endMs: 10, count: 5),
                .init(startMs: 599_990, endMs: 900_000, count: 1),
                .init(startMs: 700_000, endMs: 710_000, count: 1),
            ],
            resume: []
        )
        let fitted = try #require(PerformanceReport(measured: measured))
        // Each report gets its own ID.
        #expect(try #require(PerformanceReport(measured: measured)).id != fitted.id)
        #expect(fitted.platform == .mac)
        #expect(fitted.build == "0.1.7")
        #expect(fitted.os == "27.2")
        #expect(fitted.device == "Mac15,6")
        #expect(fitted.periodStart == Date(timeIntervalSince1970: 1_794_441_600))
        #expect(fitted.periodEnd == Date(timeIntervalSince1970: 1_794_528_001))
        #expect(fitted.scrollHitchMsPerS == 2.25)
        // Whole milliseconds, in order, without empty buckets or any past the Worker's ten minutes.
        #expect(fitted.launch == [
            .init(startMs: 0, endMs: 10, count: 5),
            .init(startMs: 310, endMs: 321, count: 2),
            .init(startMs: 599_990, endMs: 600_000, count: 1),
        ])
        #expect(fitted.resume == [])
    }

    @Test func theOSVersionIsTheFirstDottedNumber() {
        #expect(PerformanceReport.dotted("iPhone OS 27.2 (24C101)") == "27.2")
        #expect(PerformanceReport.dotted("Version 27.2.1 (Build 26C5)") == "27.2.1")
        #expect(PerformanceReport.dotted("27") == "27")
        #expect(PerformanceReport.dotted("macOS") == nil)
        #expect(PerformanceReport.dotted("27..2") == nil)
        #expect(PerformanceReport.dotted(String(repeating: "1", count: 21)) == nil)
    }

    @Test func aBuildOrDeviceTheWorkerWouldRefuseMakesNoReport() {
        let good = PerformanceReport.Measured(
            platform: .ios, build: "42", os: "iPhone OS 27.2", device: "iPhone16,2",
            periodStart: 1, periodEnd: 2, scrollHitch: nil, launch: [], resume: nil
        )
        #expect(PerformanceReport(measured: good) != nil)
        for change in [
            { (m: inout PerformanceReport.Measured) in m.build = "1.0-beta" },
            { $0.build = "" },
            { $0.os = "unknown" },
            { $0.device = "  " },
            { $0.periodStart = 3 },
            { $0.periodEnd = .nan },
        ] {
            var measured = good
            change(&measured)
            #expect(PerformanceReport(measured: measured) == nil)
        }
    }

    @Test func hitchRatiosBecomeMillisecondsPerSecond() {
        #expect(PerformanceReport.msPerSecond(.init(value: 3, unit: "ms per s")) == 3)
        #expect(PerformanceReport.msPerSecond(.init(value: 0.004, unit: "")) == 4)
        #expect(PerformanceReport.msPerSecond(.init(value: 5000, unit: "ms per s")) == 1000)
        #expect(PerformanceReport.msPerSecond(.init(value: -1, unit: "ms per s")) == 0)
        #expect(PerformanceReport.msPerSecond(.init(value: .infinity, unit: "ms per s")) == nil)
    }

    @Test func aLongHistogramIsMergedClosestNeighboursFirst() {
        let measured = (0..<60).map { PerformanceReport.Measured.Bucket(startMs: Double($0 * 10), endMs: Double($0 * 10 + 10), count: 1) }
        let buckets = PerformanceReport.buckets(measured)
        #expect(buckets.count == PerformanceReport.maxBuckets)
        #expect(buckets.reduce(0) { $0 + $1.count } == 60)
        // Still in order, end to end, covering what it did.
        #expect(buckets.first?.startMs == 0)
        #expect(buckets.last?.endMs == 600)
        #expect(zip(buckets, buckets.dropFirst()).allSatisfy { $0.endMs == $1.startMs })
    }

    @Test func mergingKeepsTheGapsBetweenFarApartBuckets() {
        // 24 neighbouring buckets near the start and one far out.
        var measured = (0..<24).map { PerformanceReport.Measured.Bucket(startMs: Double($0 * 10), endMs: Double($0 * 10 + 10), count: 1) }
        measured.append(.init(startMs: 590, endMs: 600, count: 1))
        let buckets = PerformanceReport.buckets(measured)
        #expect(buckets.count == PerformanceReport.maxBuckets)
        // Two neighbours were joined; the far one stands alone, its gap kept.
        #expect(buckets.last == .init(startMs: 590, endMs: 600, count: 1))
        #expect(buckets.dropLast().last?.endMs == 240)
        #expect(buckets.contains { $0.endMs - $0.startMs == 20 && $0.count == 2 })
    }

    // MARK: The reporter

    @Test func aReportIsSentAttestedNamingAFreshChallenge() async throws {
        let worker = FakeWorker()
        let file = temporaryFile()
        await reporter(worker, file: file).deliver([report])
        let sent = try #require(worker.reportsSent.first)
        #expect(worker.reportsSent.count == 1)
        #expect(sent.url == endpoint)
        #expect(sent.value(forHTTPHeaderField: "X-Influx-Key") == "key-1")
        #expect(sent.value(forHTTPHeaderField: "X-Influx-Assertion") != nil)
        let bytes = try #require(sent.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(body.keys) == ["challenge", "report"])
        #expect(body["challenge"] as? String == "challenge-2")
        let sentReport = try JSONDecoder().decode(PerformanceReport.self, from: JSONSerialization.data(withJSONObject: body["report"]!))
        #expect(sentReport == report)
        // Nothing is left waiting.
        #expect(try fileReports(file) == [])
    }

    @Test func aReportTheWorkerDidNotTakeWaitsForTheNextLaunch() async throws {
        let worker = FakeWorker(reports: [.init(status: 503), .init(status: 429)])
        let file = temporaryFile()
        let first = reporter(worker, file: file)
        await first.deliver([report])
        #expect(try fileReports(file) == [report])
        var second = report
        second.build = "43"
        // The next delivery tries the older one first, and stops when it is refused again.
        await first.deliver([second])
        #expect(worker.reportsSent.count == 2)
        #expect(try fileReports(file) == [report, second])

        // The next launch sends both, oldest first.
        let relaunched = reporter(worker, file: file)
        #expect(await relaunched.unsent == [report, second])
        await relaunched.sendWaiting()
        #expect(worker.reportsSent.count == 4)
        #expect(try fileReports(file) == [])
        #expect(await relaunched.unsent == [])
    }

    @Test func aRefusedAttestationKeepsTheReport() async throws {
        let worker = FakeWorker(reports: [
            .init(status: 401, body: Data(#"{"error":"attestation_required"}"#.utf8)),
            .init(status: 401, body: Data(#"{"error":"attestation_required"}"#.utf8)),
            .init(status: 401, body: Data(#"{"error":"attestation_required"}"#.utf8)),
        ])
        let file = temporaryFile()
        await reporter(worker, file: file).deliver([report])
        #expect(try fileReports(file) == [report])
    }

    @Test func aMalformedReportIsDropped() async throws {
        let worker = FakeWorker(reports: [.init(status: 400, body: Data(#"{"error":"invalid_report"}"#.utf8))])
        let file = temporaryFile()
        var second = report
        second.build = "43"
        await reporter(worker, file: file).deliver([report, second])
        // The first is dropped and the second still goes.
        #expect(worker.reportsSent.count == 2)
        #expect(try fileReports(file) == [])
    }

    @Test func anInstallThatCannotAttestSendsNothing() async throws {
        let worker = FakeWorker()
        let file = temporaryFile()
        await reporter(worker, file: file, attest: FakeAppAttest(isSupported: false)).deliver([report])
        #expect(worker.http.requests.isEmpty)
        #expect(try fileReports(file) == [report])
    }

    @Test func atMostThirtyWaitAndTheOldestGoFirst() async throws {
        let worker = FakeWorker(reports: Array(repeating: .init(status: 503), count: 40))
        let file = temporaryFile()
        let reports = (1...35).map { number in
            var each = report
            each.build = "\(number)"
            return each
        }
        await reporter(worker, file: file).deliver(reports)
        let kept = try fileReports(file)
        #expect(kept.count == PerformanceReporter.limit)
        #expect(kept.first?.build == "6")
        #expect(kept.last?.build == "35")
    }

    @Test func anUnreadableFileCountsAsEmpty() async throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(await reporter(FakeWorker(), file: file).unsent == [])
    }
}
