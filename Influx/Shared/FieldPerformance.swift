// Field performance reports from TestFlight installs (ADR 0034): MetricKit's
// daily scroll-hitch and launch figures, sent to the OAuth Worker attested
// with App Attest, so performance is judged from ordinary use. Each report
// also carries what Sammy media grants did since the last one (ADR 0039).
import Foundation
import InfluxKit

@MainActor
enum FieldPerformance {
    /// The release app's bundle ID: the one TestFlight ships. Debug, Test
    /// (UI tests) and Perf builds have their own and never report.
    static let releaseBundleID = "dev.bespokebits.influx"

    /// Whether an app with this bundle ID reports: the release app, and
    /// Influx Preview, which ships through TestFlight too (ADR 0042). The
    /// signing service tells their reports apart by the attested key.
    static func reports(bundleID: String?) -> Bool {
        bundleID == releaseBundleID || bundleID == releaseBundleID + ".preview"
    }

    private static var started = false

    /// Starts reporting, after the first screen, if this is an app that
    /// reports; InfluxMetrics then subscribes to MetricKit only once the App
    /// Store confirms a TestFlight install. Reports not sent before are
    /// tried again then too. Sample, perf and test-host runs call nothing.
    static func start() {
        guard !started, reports(bundleID: Bundle.main.bundleIdentifier),
              let start = InfluxMetricsFramework.start, let file = try? supportFile("PerformanceReports.json"),
              let tallyFile = try? supportFile("SammyMediaTally.json") else { return }
        started = true
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let reporter = PerformanceReporter(attestation: .app, file: file)
        start({
            // A TestFlight install: grant counts from earlier runs of this
            // build go with the next report too.
            SammyMediaTally.shared.keep(in: tallyFile, build: build)
            Task { await reporter.sendWaiting() }
        }, { data in
            let measured = (try? JSONDecoder().decode([PerformanceReport.Measured].self, from: data as Data)) ?? []
            var reports = measured.compactMap(PerformanceReport.init(measured:))
            guard !reports.isEmpty else { return }
            // The counts since the last report go with the newest of this
            // build's, the period they mostly cover.
            if let newest = reports.indices.filter({ reports[$0].build == build }).max(by: { reports[$0].periodEnd < reports[$1].periodEnd }) {
                reports[newest].sammyMedia = SammyMediaTally.shared.take()
            }
            Task { await reporter.deliver(reports) }
        })
    }

    /// Application Support/<bundle ID>/<name>, beside the library.
    private static func supportFile(_ name: String) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appending(path: releaseBundleID, directoryHint: .isDirectory).appending(path: name)
    }
}

/// The InfluxMetrics framework's entry point, found by name the first time
/// (`EmbeddedFramework`).
private enum InfluxMetricsFramework {
    typealias Ready = @Sendable @convention(block) () -> Void
    typealias Deliver = @Sendable @convention(block) (NSData) -> Void
    typealias Start = @convention(c) (@escaping Ready, @escaping Deliver) -> Void

    static var start: Start? {
        EmbeddedFramework.symbol("influx_metrics_start", in: "InfluxMetrics").map { unsafeBitCast($0, to: Start.self) }
    }
}
