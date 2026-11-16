// Decoded images for the timeline's media and link cards, fetched and
// decoded off the main thread at the size they are drawn at. Row drawing
// reads them synchronously; a missing image is drawn as paper and fetched,
// and the row is drawn again when it lands (RowImageCache).
//
// A rich post's media is a reference, not a URL (SammyMediaReference): its
// bytes come through its account's grants (SammyMediaGrants), which ask the
// account's own server, and read them from the source's public media
// servers at the size drawn where the server says they may (ADR 0040).
import CoreGraphics
import Foundation
import ImageIO
import os
import InfluxKit

/// One image at one decoded size.
struct MediaRequest: Hashable, Sendable {
    var url: String
    /// The decoded image's longest side, in pixels.
    var pixels: Int
    /// An author's or reposter's picture, which a rich post's grants put
    /// behind its attachments (ADR 0039).
    var avatar = false

    var key: String { "\(pixels)|\(url)" }
}

final class MediaImages: Sendable {
    static let shared = MediaImages()

    /// Decoded images are about 4 bytes a pixel; this holds a few screens'
    /// worth at 3x.
    private static let costLimit = 96 * 1024 * 1024

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// A download, how many callers still wait for it, and its place in
    /// the queue for a download slot.
    private struct Loading {
        var id: UUID
        var task: Task<Bool, Never>
        var callers: Int
        /// Each waiting caller's own priority; the queue uses the lowest.
        var priorities: CallerPriorities
        var priority: Int { priorities.lowest }
    }

    private struct State {
        var loading: [String: Loading] = [:]
        /// Requests whose last load failed. One is drawn as paper and not
        /// fetched again until its wait is over, so a broken image isn't
        /// fetched on every render, and a passing failure doesn't leave an
        /// image blank for the rest of the session.
        var failed = LoadFailures()
    }

    // NSCache is thread-safe.
    nonisolated(unsafe) private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = MediaImages.costLimit
        return cache
    }()
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Fetches only from public addresses, checked at every redirect, and
    /// stops reading at `byteLimit`.
    let resolver: MediaResolver
    /// Finds the grants of the Sammy account a reference names; nil until
    /// the accounts are started, and for an account not signed in here.
    /// Static, so setting it at launch doesn't make `shared` (and its
    /// URLSession) before the first rows are drawn.
    typealias RichMediaLookup = @Sendable (_ accountID: String) async -> SammyMediaGrants?
    private static let richMedia = OSAllocatedUnfairLock<RichMediaLookup?>(initialState: nil)
    private static let byteLimit = 20 * 1024 * 1024
    private static let timeout = Duration.seconds(30)
    /// At most this many downloads at once, so a fast scroll past many
    /// media rows can't hold many bodies in memory together. A free slot
    /// goes to the waiting download with the lowest priority (#263).
    private let downloads = DownloadSlots(limit: 6)
    private static let log = Logger(subsystem: "dev.bespokebits.influx", category: "Media")

    init(resolver: MediaResolver = MediaResolver(client: URLSession.shared)) {
        self.resolver = resolver
    }

    /// Where rich post media's grants come from (`Accounts`).
    static func findRichMedia(with lookup: @escaping RichMediaLookup) {
        richMedia.withLock { $0 = lookup }
    }

    /// The grants for `reference`'s account, when it is signed in here.
    func grants(for reference: SammyMediaReference) async -> SammyMediaGrants? {
        guard let lookup = Self.richMedia.withLock({ $0 }) else { return nil }
        return await lookup(reference.accountID)
    }

    /// The decoded image if it is ready. Safe to call from any thread.
    /// `seed:` images, which only the seeded timeline uses, are made on the
    /// spot so scroll tests draw an image into every media row.
    func image(for request: MediaRequest) -> CGImage? {
        if let entry = cache.object(forKey: request.key as NSString) { return entry.image }
        guard request.url.hasPrefix("seed:"), let image = Self.seedImage(request) else { return nil }
        store(image, for: request)
        return image
    }

    /// Whether the last load of `request` failed.
    func hasFailed(_ request: MediaRequest) -> Bool {
        state.withLock { $0.failed.contains(request.key) }
    }

    /// How long until a failed `request` may be loaded again; nil when its
    /// last load didn't fail.
    func retryWait(for request: MediaRequest) -> Duration? {
        state.withLock { $0.failed.wait(for: request.key, now: .now) }
    }

    /// Fetches and decodes `request` unless it is ready or already loading.
    /// Returns whether the image is now ready; false at once while a failed
    /// request is waiting to be tried again. Cancelling the calling task
    /// stops waiting; once no caller waits, the download itself is
    /// cancelled, and a later call starts it again.
    ///
    /// `priority` orders the wait for a download slot: lowest first, so the
    /// timeline gives the rows on screen 0 and those further off more
    /// (`RowImageCache`). Every caller keeps its own priority, as `caller`
    /// (a timeline names itself, so `prioritize` moves its own), and a load
    /// waits at the lowest of its callers'.
    func load(_ request: MediaRequest, priority: Int = 0, caller: UUID = UUID()) async -> Bool {
        if image(for: request) != nil { return true }
        let joined = state.withLock { current -> (UUID, Task<Bool, Never>)? in
            if let wait = current.failed.wait(for: request.key, now: .now), wait > .zero { return nil }
            if var entry = current.loading[request.key] {
                entry.callers += 1
                let before = entry.priority
                entry.priorities.add(caller, priority)
                current.loading[request.key] = entry
                if entry.priority != before { requeue(request.key) }
                return (entry.id, entry.task)
            }
            let id = UUID()
            let task = Task.detached(priority: .utility) { [self] in
                let image = await fetch(request)
                if let image { store(image, for: request) }
                let cancelled = Task.isCancelled
                state.withLock { current in
                    if current.loading[request.key]?.id == id { current.loading[request.key] = nil }
                    // A cancelled download isn't a broken image.
                    if image != nil {
                        current.failed.clear(request.key)
                    } else if !cancelled {
                        current.failed.record(request.key, now: .now)
                        // The host only: the rest of the address can carry
                        // tokens.
                        let host = SammyMediaReference(request.url) != nil ? "rich media" : URL(string: request.url)?.host ?? "?"
                        Self.log.notice("load failed: \(host, privacy: .public) at \(request.pixels) px")
                    }
                }
                return image != nil
            }
            var priorities = CallerPriorities()
            priorities.add(caller, priority)
            current.loading[request.key] = Loading(id: id, task: task, callers: 1, priorities: priorities)
            return (id, task)
        }
        guard let (id, task) = joined else { return false }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            leave(request.key, id: id, caller: caller)
        }
    }

    /// Moves `caller`'s priority for a download still waiting for a slot.
    /// The download waits at the lowest of its callers'. Nothing happens
    /// for one that isn't loading, or that `caller` doesn't wait for.
    func prioritize(_ key: String, _ priority: Int, caller: UUID) {
        let moved = state.withLock { current -> Bool in
            guard var entry = current.loading[key] else { return false }
            let before = entry.priority
            guard entry.priorities.move(caller, to: priority) else { return false }
            current.loading[key] = entry
            return entry.priority != before
        }
        if moved { requeue(key) }
    }

    /// Tells the slot queue that `key`'s priority changed. The queue reads
    /// the priority when the update reaches it, not when it was sent, so
    /// updates that arrive out of order still leave the latest one.
    private func requeue(_ key: String) {
        Task { [downloads, state] in
            await downloads.prioritize(key) { state.withLock { $0.loading[key]?.priority } }
        }
    }

    /// One caller of a download stopped waiting; the last one cancels it.
    private func leave(_ key: String, id: UUID, caller: UUID) {
        let abandoned = state.withLock { current -> Task<Bool, Never>? in
            guard var entry = current.loading[key], entry.id == id else { return nil }
            entry.callers -= 1
            guard entry.callers <= 0 else {
                // The rest wait at their own priorities.
                let before = entry.priority
                entry.priorities.remove(caller)
                current.loading[key] = entry
                if entry.priority != before { requeue(key) }
                return nil
            }
            current.loading[key] = nil
            return entry.task
        }
        abandoned?.cancel()
    }

    private func store(_ image: CGImage, for request: MediaRequest) {
        cache.setObject(Entry(image), forKey: request.key as NSString, cost: image.bytesPerRow * image.height)
    }

    private func fetch(_ request: MediaRequest) async -> CGImage? {
        // Where a rich post's media may be read from its source is asked for
        // now, with the other rows about to show, before this waits for a
        // slot, so one request answers many of them (ADR 0040).
        let reference = SammyMediaReference(request.url)
        var accountGrants: SammyMediaGrants?
        if let reference {
            accountGrants = await self.grants(for: reference)
            accountGrants?.warm(reference)
        }
        // Cancelled while waiting for a slot: nothing was fetched. The
        // priority is read when the wait begins; later moves reach the queue.
        guard await downloads.acquire(request.key, priority: { [state] in
            state.withLock { $0.loading[request.key]?.priority ?? 0 }
        }) else { return nil }
        defer { Task { await downloads.release() } }
        // One byte over the limit tells a cut-off body, which is dropped
        // rather than decoded half way.
        let data: Data?
        if let reference {
            data = try? await accountGrants?.data(for: reference, upTo: Self.byteLimit + 1, timeout: Self.timeout,
                                                  kind: request.avatar ? .avatar : .attachment, pixels: request.pixels)
        } else {
            data = await resolver.fetch(request.url, upTo: Self.byteLimit + 1, timeout: Self.timeout)
        }
        guard let data, data.count <= Self.byteLimit else { return nil }
        return Self.decode(data, pixels: request.pixels)
    }

    /// Images larger than this many pixels aren't decoded at all: some
    /// formats decode in full before scaling down. 50 million still takes
    /// a 48-megapixel photo.
    static let maxSourcePixels = 50_000_000

    /// Decodes at `pixels` on the longest side, fully, here, so drawing it
    /// later never decodes, and never more than MediaGrid's pixel budget
    /// for the file's real shape.
    static func decode(_ data: Data, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxSourcePixels / height
        else { return nil }
        // The size asked for was worked out from the stored size, which the
        // file itself may not match, so the budget is applied again to the
        // file's real shape.
        let budget = MediaGrid.largestDecode(pixelWidth: width, pixelHeight: height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(min(pixels, budget), 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A soft two-tone gradient standing in for a photo.
    private static func seedImage(_ request: MediaRequest) -> CGImage? {
        let side = min(max(request.pixels, 1), 512)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        var hash: UInt64 = 1469598103934665603
        for byte in request.url.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let hue = CGFloat(hash % 360) / 360
        func color(_ brightness: CGFloat) -> CGColor {
            // A muted hue, close to the paper.
            let r = 0.55 + 0.25 * cos(2 * .pi * hue), g = 0.55 + 0.25 * cos(2 * .pi * (hue - 1.0 / 3)),
                b = 0.55 + 0.25 * cos(2 * .pi * (hue - 2.0 / 3))
            return CGColor(srgbRed: r * brightness, green: g * brightness, blue: b * brightness, alpha: 1)
        }
        guard let gradient = CGGradient(colorsSpace: space, colors: [color(1), color(0.7)] as CFArray, locations: [0, 1])
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
        return context.makeImage()
    }
}

/// Each caller's priority for one download, and how many times it waits:
/// the download waits at the lowest (#263), so one caller moving its own
/// never pushes back another's.
struct CallerPriorities: Equatable {
    private var byCaller: [UUID: (priority: Int, count: Int)] = [:]

    static func == (a: Self, b: Self) -> Bool {
        a.byCaller.mapValues(\.priority) == b.byCaller.mapValues(\.priority)
    }

    /// The lowest priority of any caller; 0 with none.
    var lowest: Int { byCaller.values.map(\.priority).min() ?? 0 }

    /// `caller` waits (again) at `priority`.
    mutating func add(_ caller: UUID, _ priority: Int) {
        let count = byCaller[caller]?.count ?? 0
        byCaller[caller] = (priority, count + 1)
    }

    /// Moves `caller`'s priority; false when it isn't waiting.
    mutating func move(_ caller: UUID, to priority: Int) -> Bool {
        guard let entry = byCaller[caller] else { return false }
        byCaller[caller] = (priority, entry.count)
        return true
    }

    /// One of `caller`'s waits ended.
    mutating func remove(_ caller: UUID) {
        guard let entry = byCaller[caller] else { return }
        byCaller[caller] = entry.count > 1 ? (entry.priority, entry.count - 1) : nil
    }
}

/// A counting semaphore for downloads. A free slot goes to the waiter with
/// the lowest priority, and the one that has waited longest among equals
/// (#263). The timeline asks for the images of the rows ahead nearest
/// first and keeps their priorities current as the reader scrolls, so the
/// images about to come on screen load before those of rows further off.
/// (Until 2026-11, the newest waiter went first, which served the farthest
/// row's images first.) A waiter whose task is cancelled leaves the queue.
actor DownloadSlots {
    private struct Waiter {
        let id: Int
        let key: String
        var priority: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var used = 0
    private var waiters: [Waiter] = []
    private var nextID = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Waits for a slot for the download `key`, at the priority `priority`
    /// gives when the wait begins. False, holding no slot, if the task was
    /// cancelled before one came free.
    func acquire(_ key: String, priority: @Sendable () -> Int) async -> Bool {
        guard !Task.isCancelled else { return false }
        if used < limit {
            used += 1
            return true
        }
        nextID += 1
        let id = nextID
        let start = priority()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append(Waiter(id: id, key: key, priority: start, continuation: $0)) }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
    }

    /// Moves every waiter for `key` to `priority`.
    func prioritize(_ key: String, _ priority: Int) {
        for index in waiters.indices where waiters[index].key == key {
            waiters[index].priority = priority
        }
    }

    /// Moves every waiter for `key` to the priority `current` gives now, so
    /// that updates arriving in any order leave the latest. Nil leaves them.
    func prioritize(_ key: String, current: @Sendable () -> Int?) {
        guard let priority = current() else { return }
        prioritize(key, priority)
    }

    func release() {
        guard let next = waiters.indices.min(by: { (waiters[$0].priority, waiters[$0].id) < (waiters[$1].priority, waiters[$1].id) })
        else {
            used -= 1
            return
        }
        // The slot passes straight to the next waiter.
        waiters.remove(at: next).continuation.resume(returning: true)
    }

    /// The keys waiting, in the order they would get a slot. For tests.
    var queue: [String] {
        waiters.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }.map(\.key)
    }

    private func withdraw(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
