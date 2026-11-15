import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends field performance reports to the OAuth Worker (ADR 0034), each one
/// attested by the install's App Attest key through `CallerAttestation`.
///
/// Reports wait in a small file until the Worker has them, so one that
/// couldn't be sent (offline, the Worker busy, the install unable to attest
/// just now) goes with the next delivery or at the next launch. The file
/// keeps the newest 30; older ones are dropped. A report the Worker refuses
/// as malformed is dropped too, since sending it again can't help. Nothing
/// is ever sent unattested: the Worker would only refuse it.
public actor PerformanceReporter {
    /// Where reports go.
    public static let endpoint = URL(string: "https://influx.bespokebits.dev/perf/report")!
    /// The most reports kept waiting.
    public static let limit = 30

    /// Why a report wasn't sent this time; it stays waiting.
    struct NotAttested: Error {}

    private let attestation: CallerAttestation
    private let file: URL
    private let endpoint: URL
    private var waiting: [PerformanceReport]
    private var sending = false

    /// `file` keeps the reports not yet sent; one that can't be read counts
    /// as empty.
    public init(attestation: CallerAttestation, file: URL, endpoint: URL = PerformanceReporter.endpoint) {
        self.attestation = attestation
        self.file = file
        self.endpoint = endpoint
        waiting = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([PerformanceReport].self, from: $0) } ?? []
    }

    /// The reports still waiting, oldest first.
    public var unsent: [PerformanceReport] { waiting }

    /// Keeps `reports` and sends everything waiting.
    public func deliver(_ reports: [PerformanceReport]) async {
        waiting += reports
        if waiting.count > Self.limit { waiting.removeFirst(waiting.count - Self.limit) }
        save()
        await sendWaiting()
    }

    /// Sends what is waiting, oldest first, stopping at the first that the
    /// Worker doesn't take for a reason a later try could get past. A call
    /// made while another is sending leaves it to that one.
    public func sendWaiting() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        while let report = waiting.first {
            guard await send(report) else { return }
            // A delivery while it was sending may have dropped it already.
            if let index = waiting.firstIndex(of: report) { waiting.remove(at: index) }
            save()
        }
    }

    /// Whether the report is done with: the Worker stored it, or refused it
    /// as malformed. False when it should be tried again later.
    private func send(_ report: PerformanceReport) async -> Bool {
        struct Body: Encodable {
            var challenge: String
            var report: PerformanceReport
        }
        do {
            let (_, response) = try await attestation.send(to: endpoint) { challenge in
                guard let challenge else { throw NotAttested() }
                return try JSONEncoder().encode(Body(challenge: challenge, report: report))
            }
            return (200..<300).contains(response.statusCode) || response.statusCode == 400
        } catch {
            return false
        }
    }

    private func save() {
        // Written beside the file and renamed over it, so a run that stops
        // part way leaves the old file whole. (`.atomic` writes through a
        // system folder some sandboxes can't reach.)
        let written = file.appendingPathExtension("new")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(waiting).write(to: written)
            guard rename(written.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            // The reports are still in memory for this run.
            try? FileManager.default.removeItem(at: written)
        }
    }
}
