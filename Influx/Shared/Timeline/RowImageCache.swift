// Row bitmaps for the rows around the viewport. Rows ahead of the scroll are
// rendered off the main thread, nearest first, so a cell normally finds its
// image ready. Nothing is ever drawn on the main thread: a miss shows plain
// paper, renders at once in the background, and `onReady` fills the cell in.
// A row drawn before its images loaded is drawn again when they land.
import CoreGraphics
import Foundation
import InfluxKit

@MainActor
final class RowImageCache {
    /// Rows rendered ahead of the visible range in the scroll direction, and
    /// behind it. 24 both ways missed 33 rows in 31 s of trackpad flings
    /// during the prototype.
    static let ahead = 48
    static let behind = 8
    /// Rows kept around the visible range before eviction.
    static let keep = 64
    /// The most the kept bitmaps may take, as estimated from their pixel
    /// sizes. Row bitmaps are a whole row wide at the display's scale, so
    /// 64 rows each way held about 500 MB on a Mac, with Core Animation
    /// holding another 250 MB beside them. Rows beyond the budget are
    /// dropped farthest first; the visible rows always stay. The budget
    /// still holds the whole prefetch window for typical rows.
    #if os(macOS)
    static let byteBudget = 192 * 1024 * 1024
    #else
    static let byteBudget = 320 * 1024 * 1024
    #endif

    private(set) var misses = 0
    /// Called with a row's merge key when its bitmap arrives after a miss.
    var onReady: ((String) -> Void)?
    private var environment: RowEnvironment?
    private var images: [String: CGImage] = [:]
    /// Rows with a render in flight, and the ticket of the newest request.
    /// Only that request's bitmap is kept, so a bitmap of content that has
    /// since changed never lands.
    private var queued: [String: Int] = [:]
    private var nextTicket = 0
    /// Rows shown blank after a miss, to fill in when their bitmap lands.
    private var waiting: Set<String> = []
    private var generation = 0
    private var lastVisible: Range<Int>?
    /// The content each kept bitmap was drawn from, to draw it again when
    /// its images land.
    private var drawn: [String: (TimelineRow, RowGeometry)] = [:]
    /// Rows drawn without an image, by the image's request key.
    private var awaitingMedia: [String: Set<String>] = [:]
    /// The load for each request in `awaitingMedia`, cancelled once no kept
    /// row wants it.
    private var mediaLoads: [String: Task<Void, Never>] = [:]
    private let media: MediaImages

    init(media: MediaImages = .shared) {
        self.media = media
    }

    /// Drops every image when the width, scale, appearance or text size
    /// changes.
    func use(_ newEnvironment: RowEnvironment) {
        guard newEnvironment != environment else { return }
        environment = newEnvironment
        images.removeAll()
        queued.removeAll()
        waiting.removeAll()
        drawn.removeAll()
        mediaLoads.values.forEach { $0.cancel() }
        mediaLoads.removeAll()
        awaitingMedia.removeAll()
        generation += 1
        lastVisible = nil
    }

    /// Drops the images of rows whose content changed. A row on screen keeps
    /// its old bitmap until the new one is ready.
    func invalidate(_ keys: [String], visible: Set<String>, rows: [String: (TimelineRow, RowGeometry)]) {
        guard let environment else { return }
        var urgent: [Job] = []
        for key in keys {
            queued[key] = nil
            if visible.contains(key), let (row, geometry) = rows[key] {
                waiting.insert(key)
                urgent.append(job(row, geometry))
            } else {
                images[key] = nil
                drawn[key] = nil
            }
        }
        if !urgent.isEmpty {
            render([urgent], environment: environment, urgent: true)
        }
        lastVisible = nil
    }

    /// Drops everything kept for rows that left the timeline or came back,
    /// so a merge key that returns with new content never shows its old
    /// bitmap.
    func forget(_ keys: [String]) {
        for key in keys {
            images[key] = nil
            queued[key] = nil
            waiting.remove(key)
            drawn[key] = nil
        }
        stopLoading(for: Set(keys))
    }

    /// Bitmaps drawn before the timeline was on screen, for the environment
    /// it's in now. `rows` holds what each was drawn from.
    func seed(_ rendered: [RowImage], rows: [String: (TimelineRow, RowGeometry)]) {
        for image in rendered {
            guard let content = rows[image.key] else { continue }
            images[image.key] = image.image
            drawn[image.key] = content
            loadMissing(image)
        }
    }

    func resetCounters() {
        misses = 0
    }

    func image(for row: TimelineRow, geometry: RowGeometry) -> CGImage? {
        if let image = images[row.mergeKey] { return image }
        guard let environment else { return nil }
        misses += 1
        // Drawing here cost a frame at 120 Hz (224 misses in 19 s on an
        // iPhone 15 Pro Max), so render it now off main, even if a prefetch
        // lane already has it queued behind other rows.
        waiting.insert(row.mergeKey)
        render([[job(row, geometry)]], environment: environment, urgent: true)
        return nil
    }

    /// Call when the visible rows change. Evicts far rows and renders the
    /// rows around `visible` that aren't ready, nearest first.
    func prefetch(around visible: Range<Int>, in model: TimelineModel) {
        guard let environment, model.count > 0, visible != lastVisible else { return }
        let down = visible.lowerBound >= (lastVisible?.lowerBound ?? 0)
        lastVisible = visible
        let count = model.count

        let budgeted = Self.keptRows(around: visible, down: down, count: count, budget: Self.byteBudget) { row in
            Self.bytes(width: model.geometries[row].width, height: model.geometries[row].height, scale: environment.scale)
        }
        let keptKeys = Set(budgeted.map { model.rows[$0].mergeKey })
        images = images.filter { keptKeys.contains($0.key) }
        drawn = drawn.filter { keptKeys.contains($0.key) }
        // Renders still in flight for rows now out of range are dropped
        // when they land, since only a queued ticket's bitmap is kept.
        queued = queued.filter { keptKeys.contains($0.key) }
        stopLoading(for: Set(awaitingMedia.values.joined()).subtracting(keptKeys))

        let above = down ? Self.behind : Self.ahead
        let below = down ? Self.ahead : Self.behind
        let wanted = max(0, visible.lowerBound - above)..<min(count, visible.upperBound + below)
        // Visible rows first, then onward in the scroll direction, then the
        // few rows behind.
        func priority(_ row: Int) -> Int {
            if down {
                return row >= visible.lowerBound ? row - visible.lowerBound : Self.ahead * 2 + visible.lowerBound - row
            }
            return row < visible.upperBound ? visible.upperBound - 1 - row : Self.ahead * 2 + row - visible.upperBound
        }
        let jobs = wanted
            .filter { keptKeys.contains(model.rows[$0].mergeKey) }
            .filter { images[model.rows[$0].mergeKey] == nil && queued[model.rows[$0].mergeKey] == nil }
            .sorted { priority($0) < priority($1) }
            .map { job(model.rows[$0], model.geometries[$0]) }
        guard !jobs.isEmpty else { return }

        let batches = stride(from: 0, to: jobs.count, by: 4).map { Array(jobs[$0..<min($0 + 4, jobs.count)]) }
        render(batches, environment: environment, urgent: false)
    }

    /// The rows to keep bitmaps for, in the order they are wanted: the
    /// visible rows, then the prefetch window (onward in the scroll
    /// direction, then the few behind), then the rest of `keep`, onward
    /// first, until `budget` bytes are used. The visible rows are always
    /// included.
    static func keptRows(around visible: Range<Int>, down: Bool, count: Int, budget: Int,
                         bytes: (Int) -> Int) -> [Int] {
        let visible = visible.clamped(to: 0..<count)
        let above = down ? behind : ahead
        let below = down ? ahead : behind
        var order = Array(visible)
        // The prefetch window, onward first.
        let onward = down
            ? Array(visible.upperBound..<min(count, visible.upperBound + below))
            : Array((max(0, visible.lowerBound - above)..<visible.lowerBound).reversed())
        let back = down
            ? Array((max(0, visible.lowerBound - above)..<visible.lowerBound).reversed())
            : Array(visible.upperBound..<min(count, visible.upperBound + below))
        order += onward + back
        // Then the rest of `keep`, onward first.
        let windowLow = max(0, visible.lowerBound - above), windowHigh = min(count, visible.upperBound + below)
        let keptLow = max(0, visible.lowerBound - keep), keptHigh = min(count, visible.upperBound + keep)
        var up = windowLow - 1, downward = windowHigh
        while up >= keptLow || downward < keptHigh {
            if downward < keptHigh, down || up < keptLow { order.append(downward); downward += 1 }
            else if up >= keptLow { order.append(up); up -= 1 }
        }

        var used = 0
        var kept: [Int] = []
        for (index, row) in order.enumerated() {
            used += bytes(row)
            if index >= visible.count, used > budget { break }
            kept.append(row)
        }
        return kept
    }

    /// A row bitmap's size in bytes, at 4 bytes a pixel.
    static func bytes(width: CGFloat, height: CGFloat, scale: CGFloat) -> Int {
        Int((width * scale).rounded(.up)) * Int((height * scale).rounded(.up)) * 4
    }

    private struct Job: Sendable {
        var row: TimelineRow
        var geometry: RowGeometry
        var ticket: Int
    }

    private struct Rendered: Sendable {
        var image: RowImage
        var job: Job
    }

    /// Loads the images a row was drawn without, then draws the rows that
    /// wanted each one again, if they're still kept and nothing newer is
    /// already on its way. A load that fails draws them once straight
    /// away, so a missing avatar turns into its monogram, and is tried
    /// again after its wait for as long as a kept row wants it, so a
    /// passing failure doesn't leave an image blank. Rows drawn
    /// meanwhile join the load already waiting rather than starting
    /// another, so this can't loop.
    private func loadMissing(_ rendered: RowImage) {
        for request in rendered.missing {
            let alreadyLoading = awaitingMedia[request.key] != nil
            awaitingMedia[request.key, default: []].insert(rendered.key)
            guard !alreadyLoading else { continue }
            let generation = self.generation
            // Held weakly, so a cache that is let go while an image keeps
            // failing stops trying after its current wait.
            mediaLoads[request.key] = Task { [weak self, media = self.media] in
                var drewFailure = false
                while true {
                    let loaded = await media.load(request)
                    guard let wait = self?.landed(request, loaded: loaded, generation: generation, drewFailure: &drewFailure)
                    else { return }
                    try? await Task.sleep(for: max(wait, .milliseconds(100)))
                    if Task.isCancelled { return }
                }
            }
        }
    }

    /// Handles one attempt at `request`: draws its rows again, and returns
    /// how long to wait before trying again, or nil when it's done.
    private func landed(_ request: MediaRequest, loaded: Bool, generation: Int, drewFailure: inout Bool) -> Duration? {
        guard generation == self.generation, !Task.isCancelled else { return nil }
        if !loaded, let wait = media.retryWait(for: request) {
            if !drewFailure, let keys = awaitingMedia[request.key] {
                drewFailure = true
                redraw(keys)
            }
            return wait
        }
        mediaLoads[request.key] = nil
        guard let keys = awaitingMedia.removeValue(forKey: request.key) else { return nil }
        if loaded || media.hasFailed(request) { redraw(keys) }
        return nil
    }

    /// Takes `keys` off the loads they were waiting for, and cancels each
    /// load no kept row wants any more, so a fast scroll doesn't leave a
    /// backlog of downloads for rows far behind.
    private func stopLoading(for keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for (request, rows) in awaitingMedia where !rows.isDisjoint(with: keys) {
            let remaining = rows.subtracting(keys)
            if remaining.isEmpty {
                awaitingMedia[request] = nil
                mediaLoads.removeValue(forKey: request)?.cancel()
            } else {
                awaitingMedia[request] = remaining
            }
        }
    }

    private func redraw(_ keys: Set<String>) {
        guard let environment else { return }
        let jobs = keys.compactMap { key -> Job? in
            guard queued[key] == nil, images[key] != nil, let (row, geometry) = drawn[key] else { return nil }
            // Fills the cell in if the row is on screen.
            waiting.insert(key)
            return job(row, geometry)
        }
        guard !jobs.isEmpty else { return }
        render(stride(from: 0, to: jobs.count, by: 4).map { Array(jobs[$0..<min($0 + 4, jobs.count)]) },
               environment: environment, urgent: false)
    }

    /// A render request for `row`; it supersedes any earlier one.
    private func job(_ row: TimelineRow, _ geometry: RowGeometry) -> Job {
        nextTicket += 1
        queued[row.mergeKey] = nextTicket
        return Job(row: row, geometry: geometry, ticket: nextTicket)
    }

    /// Renders batches on several cores at once, in order, and stores them.
    private func render(_ batches: [[Job]], environment: RowEnvironment, urgent: Bool) {
        let generation = self.generation
        let lanes = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        let media = self.media
        Task {
            await withTaskGroup(of: [Rendered].self) { group in
                var next = 0
                func startNext() {
                    guard next < batches.count else { return }
                    let batch = batches[next]
                    next += 1
                    group.addTask(priority: urgent ? .high : .userInitiated) {
                        batch.compactMap { job in
                            RowRenderer.render(job.row, geometry: job.geometry, in: environment, media: media)
                                .map { Rendered(image: $0, job: job) }
                        }
                    }
                }
                for _ in 0..<lanes { startNext() }
                for await rendered in group {
                    if generation == self.generation {
                        for result in rendered where queued[result.image.key] == result.job.ticket {
                            let key = result.image.key
                            queued[key] = nil
                            images[key] = result.image.image
                            drawn[key] = (result.job.row, result.job.geometry)
                            if waiting.remove(key) != nil { onReady?(key) }
                            loadMissing(result.image)
                        }
                    }
                    startNext()
                }
            }
        }
    }
}
