// Field performance figures (ADR 0034), in a framework of its own: the app
// embeds it without linking it and loads it after the first screen, so
// MetricKit and StoreKit stay out of launch (as InfluxSync does for
// CloudKit). The app calls `influx_metrics_start` through dlsym.
//
// This file only reads: StoreKit says whether this is a TestFlight install,
// and MetricKit hands over each day's payload. What a payload becomes, and
// sending it, is InfluxKit's (`PerformanceReport`, `PerformanceReporter`),
// which this framework must not link, because the app links it statically.
// So figures cross this boundary as JSON, in the shape of InfluxKit's
// `PerformanceReport.Measured`.
import Foundation
import MetricKit
import os
import StoreKit

/// Called once this install is known to be a TestFlight one and MetricKit
/// will deliver to it.
public typealias Ready = @Sendable @convention(block) () -> Void
/// Hands the app one MetricKit delivery's figures, as a JSON array of
/// `PerformanceReport.Measured`.
public typealias Deliver = @Sendable @convention(block) (NSData) -> Void

private let log = Logger(subsystem: "dev.bespokebits.influx", category: "Metrics")

/// The subscriber, kept here because MetricKit doesn't keep it.
private let current = OSAllocatedUnfairLock<Subscriber?>(initialState: nil)

/// Subscribes to MetricKit if, and only if, the App Store's app transaction
/// names the sandbox environment, as TestFlight's does (and a
/// development-signed build's, which `isTestFlightApp` then leaves out): an
/// App Store or Xcode build reports nothing. Returns at once;
/// the check runs in the background. Calling it again does nothing.
@_cdecl("influx_metrics_start")
public func influx_metrics_start(_ ready: @escaping Ready, _ deliver: @escaping Deliver) {
    Task.detached(priority: .utility) {
        guard await isTestFlight() else { return }
        let subscriber = Subscriber(deliver: deliver)
        let added = current.withLock { current in
            guard current == nil else { return false }
            current = subscriber
            return true
        }
        guard added else { return }
        MXMetricManager.shared.add(subscriber)
        ready()
    }
}

/// Whether the App Store's signed record of this install says TestFlight.
private func isTestFlight() async -> Bool {
    do {
        guard case let .verified(transaction) = try await AppTransaction.shared else {
            log.notice("app transaction unverified: no field reports")
            return false
        }
        return transaction.environment == .sandbox
    } catch {
        log.notice("no app transaction (\(error.localizedDescription, privacy: .public)): no field reports")
        return false
    }
}

private final class Subscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    let deliver: Deliver

    init(deliver: @escaping Deliver) {
        self.deliver = deliver
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // A development-signed build also gets a sandbox app transaction,
        // so each payload must also say it came from a TestFlight install.
        // (The Worker refuses a development-signed build's attestation too.)
        // A payload that spans an update mixes two builds' figures, which
        // can't be told apart, so it is left out.
        let testFlight = payloads.filter { $0.metaData?.isTestFlightApp == true && !$0.includesMultipleApplicationVersions }
        guard !testFlight.isEmpty, let json = try? JSONEncoder().encode(testFlight.map(Measured.init)) else { return }
        deliver(json as NSData)
    }
}

/// InfluxKit's `PerformanceReport.Measured`, field for field.
private struct Measured: Encodable {
    struct Ratio: Encodable {
        var value: Double
        var unit: String
    }

    struct Bucket: Encodable {
        var startMs: Double
        var endMs: Double
        var count: Int
    }

    var platform: String
    var build: String
    var os: String
    var device: String
    var periodStart: Double
    var periodEnd: Double
    var scrollHitch: Ratio?
    var launch: [Bucket]
    var resume: [Bucket]?

    init(_ payload: MXMetricPayload) {
        let meta = payload.metaData
        #if os(iOS)
        platform = "ios"
        // In ms per second of scrolling. MetricKit measures it only for
        // UIScrollView, which the iPhone's timeline is.
        scrollHitch = payload.animationMetrics.map { Ratio(value: $0.scrollHitchTimeRatio.value, unit: $0.scrollHitchTimeRatio.unit.symbol) }
        #else
        platform = "mac"
        // MetricKit has the ratio on macOS, but measures it only for
        // UIScrollView, so the Mac's NSCollectionView timeline would always
        // read as hitch-free. Sent as not measured instead.
        scrollHitch = nil
        #endif
        build = meta?.applicationBuildVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        os = meta?.osVersion ?? ProcessInfo.processInfo.operatingSystemVersionString
        device = meta?.deviceType ?? Self.hardwareModel()
        periodStart = payload.timeStampBegin.timeIntervalSince1970
        periodEnd = payload.timeStampEnd.timeIntervalSince1970
        let launches = payload.applicationLaunchMetrics
        launch = launches.map { Self.buckets($0.histogrammedTimeToFirstDraw) } ?? []
        resume = launches.map { Self.buckets($0.histogrammedApplicationResumeTime) }
    }

    static func buckets(_ histogram: MXHistogram<UnitDuration>) -> [Bucket] {
        histogram.bucketEnumerator.compactMap { element in
            guard let bucket = element as? MXHistogramBucket<UnitDuration> else { return nil }
            return Bucket(
                startMs: bucket.bucketStart.converted(to: .milliseconds).value,
                endMs: bucket.bucketEnd.converted(to: .milliseconds).value,
                count: bucket.bucketCount
            )
        }
    }

    /// The hardware model, such as "iPhone16,2" or "Mac15,6", for a payload
    /// without metadata.
    static func hardwareModel() -> String {
        #if os(iOS)
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
        #endif
    }
}
