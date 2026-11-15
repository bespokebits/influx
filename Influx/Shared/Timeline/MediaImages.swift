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

    /// A download and how many callers still wait for it.
    private struct Loading {
        var id: UUID
        var task: Task<Bool, Never>
        var callers: Int
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
    /// media rows can't hold many bodies in memory together.
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
    func load(_ request: MediaRequest) async -> Bool {
        if image(for: request) != nil { return true }
        let joined = state.withLock { current -> (UUID, Task<Bool, Never>)? in
            if let wait = current.failed.wait(for: request.key, now: .now), wait > .zero { return nil }
            if var entry = current.loading[request.key] {
                entry.callers += 1
                current.loading[request.key] = entry
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
            current.loading[request.key] = Loading(id: id, task: task, callers: 1)
            return (id, task)
        }
        guard let (id, task) = joined else { return false }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            leave(request.key, id: id)
        }
    }

    /// One caller of a download stopped waiting; the last one cancels it.
    private func leave(_ key: String, id: UUID) {
        let abandoned = state.withLock { current -> Task<Bool, Never>? in
            guard var entry = current.loading[key], entry.id == id else { return nil }
            entry.callers -= 1
            guard entry.callers <= 0 else {
                current.loading[key] = entry
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
        // Cancelled while waiting for a slot: nothing was fetched.
        guard await downloads.acquire() else { return nil }
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

/// A counting semaphore for downloads. The newest waiter goes first: after
/// a fast scroll the newest requests are for the rows now on screen, and
/// the old ones for rows already scrolled past. A waiter whose task is
/// cancelled leaves the queue.
private actor DownloadSlots {
    private let limit: Int
    private var used = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextID = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Waits for a slot. False, holding no slot, if the task was cancelled
    /// before one came free.
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if used < limit {
            used += 1
            return true
        }
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            used -= 1
        } else {
            // The slot passes straight to the newest waiter.
            waiters.removeLast().continuation.resume(returning: true)
        }
    }

    private func withdraw(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
