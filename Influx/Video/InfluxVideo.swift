// Video playback, in a framework of its own: the app embeds it without
// linking it and loads it on the first tap on a video, so AVFoundation and
// AVKit stay out of launch (see WebSignIn for the same with sign-in). The
// app calls `influx_video_play` and `influx_video_stop` through dlsym.
//
// Videos play only when the reader taps one: the system player opens with
// its own controls and sound (AVPlayerViewController on iOS, an AVPlayerView
// window on macOS). Nothing in the timeline plays by itself, so scrolling
// never decodes video.
//
// A video's address comes from someone's post, so it is fetched like an
// image: a movie file through PinnedVideoLoader, which reads it through the
// app's pinned fetch, or for a rich post through its account's grants.
// Which videos may play, streams included, the app decides before calling
// (VideoPlayback).
import AVKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The app's answer to one ranged fetch: status (0 when it failed), the
/// file's whole length (-1 when unknown), content type and bytes.
public typealias Fetched = @Sendable @convention(block) (Int, Int, NSString?, NSData?) -> Void
/// Fetches bytes lower...upper of a URL, at most a limit, within a timeout
/// in seconds, through the app's MediaResolver.
public typealias Fetch = @Sendable @convention(block) (NSString, Int, Int, Int, Double, @escaping Fetched) -> Void

/// What a ranged fetch brought back.
struct Ranged {
    var data: Data
    var statusCode: Int
    var contentType: String?
    var totalLength: Int?
}

/// The video playing now, if any. Playing another stops it.
@MainActor private var current: VideoPlayer?

/// Plays a video the reader tapped: full screen over `presenter` on iOS,
/// in the player window on macOS (sized to `aspect`, width over height).
/// False when the video can't be played.
@_cdecl("influx_video_play")
public func influx_video_play(_ presenter: NSObject?, _ url: NSString, _ gif: Bool, _ stream: Bool,
                            _ aspect: Double, _ fetch: @escaping Fetch) -> Bool {
    // Called on the main thread; the presenter is the app's view controller.
    let url = url as String
    nonisolated(unsafe) let presenter = presenter
    return MainActor.assumeIsolated {
        #if os(iOS)
        guard let presenter = presenter as? UIViewController else { return false }
        #endif
        guard let video = VideoPlayer(url: url, gif: gif, stream: stream, fetch: fetch) else { return false }
        current?.stop()
        current = video
        #if os(iOS)
        let player = AVPlayerViewController()
        player.player = video.player
        // Picture in picture would need background audio, and closing the
        // player stops the video.
        player.allowsPictureInPicturePlayback = false
        player.modalPresentationStyle = .fullScreen
        presenter.present(player, animated: true) { video.player.play() }
        #else
        let window = VideoWindow.shared.window
        (window.contentView as? AVPlayerView)?.player = video.player
        // Fits a 960 by 720 box, so a tall video isn't taller than the screen.
        let aspect = CGFloat(aspect)
        window.setContentSize(aspect >= 960.0 / 720 ? NSSize(width: 960, height: (960 / aspect).rounded())
                                                    : NSSize(width: (720 * aspect).rounded(), height: 720))
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        window.makeKeyAndOrderFront(nil)
        video.player.play()
        #endif
        return true
    }
}

/// Stops the video playing now, if any; on macOS, closes its window.
@_cdecl("influx_video_stop")
public func influx_video_stop() {
    MainActor.assumeIsolated {
        current?.stop()
        current = nil
        #if os(macOS)
        VideoWindow.shared.close()
        #endif
    }
}

#if os(macOS)
/// The one player window, made on the first video and reused. Closing it
/// stops the video.
@MainActor
private final class VideoWindow: NSObject {
    static let shared = VideoWindow()
    private var made: NSWindow?

    var window: NSWindow {
        if let made { return made }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Video"
        window.isReleasedWhenClosed = false
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.allowsPictureInPicturePlayback = false
        window.contentView = playerView
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(closed),
                                               name: NSWindow.willCloseNotification, object: window)
        made = window
        return window
    }

    func close() {
        made?.close()
    }

    @objc private func closed() {
        current?.stop()
        current = nil
        (made?.contentView as? AVPlayerView)?.player = nil
    }
}
#endif

/// A player for one tapped video. Gifs loop; videos play once.
@MainActor
final class VideoPlayer {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    /// Kept for as long as the player reads through it.
    private var loader: PinnedVideoLoader?

    init?(url: String, gif: Bool, stream: Bool, fetch: @escaping Fetch) {
        guard let address = URL(string: url) else { return nil }
        let asset: AVURLAsset
        if stream {
            asset = AVURLAsset(url: address)
        } else {
            guard let loader = PinnedVideoLoader(url: url, fetch: fetch) else { return nil }
            self.loader = loader
            asset = loader.asset
        }
        let item = AVPlayerItem(asset: asset)
        if gif {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            // Stays on the last frame at the end, so it can be replayed or scrubbed.
            player.actionAtItemEnd = .pause
            player.insert(item, after: nil)
        }
        #if os(iOS)
        // The reader asked for this video, so it plays with sound, even with
        // the silent switch on, like other video apps.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #endif
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        loader = nil
        #if os(iOS)
        // Lets music the video interrupted carry on.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// Feeds an AVURLAsset through the app's pinned fetch (MediaResolver): AVPlayer
/// asks for byte ranges of a stand-in URL, and each is fetched with the same
/// public-address, redirect and size checks as an image.
final class PinnedVideoLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// The most of one video the timeline will fetch.
    static let byteLimit = 100 * 1024 * 1024
    /// The most fetched for one data request; AVPlayer asks again for more.
    static let chunk = 1024 * 1024
    static let timeout = Duration.seconds(30)
    private static let scheme = "influx-pinned"
    private static let queue = DispatchQueue(label: "dev.bespokebits.influx.video-loader")

    let asset: AVURLAsset
    private let source: String
    private let fetch: Fetch
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The file's length, once the content information request has it.
    private var knownLength: Int?

    init?(url: String, fetch: @escaping Fetch) {
        guard var parts = URLComponents(string: url), let scheme = parts.scheme else { return nil }
        let standIn: URL?
        if scheme == "https" {
            parts.scheme = Self.scheme
            standIn = parts.url
        } else {
            // A reference the app reads itself (a rich post's media), which
            // has no path worth keeping.
            standIn = URL(string: "\(Self.scheme)://media/\(UUID().uuidString)")
        }
        guard let standIn else { return nil }
        source = url
        self.fetch = fetch
        // A movie can point at other files by URL, which AVFoundation would
        // load itself, around the loader; refuse them all.
        asset = AVURLAsset(url: standIn, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        super.init()
        asset.resourceLoader.setDelegate(self, queue: Self.queue)
    }

    deinit {
        lock.withLock { tasks.values.forEach { $0.cancel() } }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        let request = LoadingRequest(loadingRequest)
        let id = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.serve(request)
            _ = self?.lock.withLock { self?.tasks.removeValue(forKey: id) }
        }
        lock.withLock { tasks[id] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancel()
    }

    /// One ranged fetch through the app; nil when it failed.
    private func ranged(_ bytes: ClosedRange<Int>, upTo limit: Int) async -> Ranged? {
        let source = source as NSString, fetch = fetch
        return await withCheckedContinuation { continuation in
            fetch(source, bytes.lowerBound, bytes.upperBound, limit, Double(Self.timeout.components.seconds)) { status, total, type, data in
                continuation.resume(returning: status == 0 ? nil : Ranged(
                    data: (data as Data?) ?? Data(), statusCode: status,
                    contentType: type as String?, totalLength: total < 0 ? nil : total))
            }
        }
    }

    private func serve(_ request: LoadingRequest) async {
        let loading = request.value
        func fail(_ code: URLError.Code) {
            if !Task.isCancelled { loading.finishLoading(with: URLError(code)) }
        }

        if let info = loading.contentInformationRequest {
            guard let head = await ranged(0...1, upTo: 2), !Task.isCancelled else {
                return fail(.cannotLoadFromNetwork)
            }
            // Only servers that answer byte ranges: AVPlayer reads a movie in
            // pieces. A video of unknown length could be any size, so it
            // isn't played either.
            guard head.statusCode == 206 else { return fail(.cannotParseResponse) }
            guard let total = head.totalLength, total > 0, total <= Self.byteLimit else {
                return fail(.dataLengthExceedsMaximum)
            }
            // Only a movie file: never a playlist, whose entries AVFoundation
            // would fetch itself, around the loader.
            guard let type = head.contentType.flatMap({ UTType(mimeType: $0) }),
                  type.conforms(to: .movie), !type.conforms(to: .m3uPlaylist)
            else { return fail(.cannotDecodeContentData) }
            info.contentType = type.identifier
            info.contentLength = Int64(total)
            info.isByteRangeAccessSupported = true
            lock.withLock { knownLength = total }
        }

        guard let data = loading.dataRequest else {
            loading.finishLoading()
            return
        }
        // Every byte asked for is sent before the request is finished, a
        // chunk at a time, so a long request never sits in memory whole.
        let fileEnd = min(lock.withLock { knownLength } ?? Self.byteLimit, Self.byteLimit)
        let end = data.requestsAllDataToEndOfResource
            ? fileEnd
            : min(Int(data.requestedOffset) + data.requestedLength, fileEnd)
        var offset = Int(data.currentOffset)
        while offset < end {
            let wanted = offset...(min(offset + Self.chunk, end) - 1)
            guard let response = await ranged(wanted, upTo: wanted.count),
                  !Task.isCancelled
            else { return fail(.cannotLoadFromNetwork) }
            guard response.statusCode == 206 else { return fail(.cannotParseResponse) }
            guard !response.data.isEmpty else { break }
            data.respond(with: response.data)
            offset += response.data.count
            // A short answer is the end of the file.
            if response.data.count < wanted.count { break }
        }
        // Asked for more than a video may be: the rest is refused.
        if !data.requestsAllDataToEndOfResource, offset < Int(data.requestedOffset) + data.requestedLength,
           offset >= Self.byteLimit {
            return fail(.dataLengthExceedsMaximum)
        }
        loading.finishLoading()
    }
}

/// AVAssetResourceLoadingRequest is used from the loader's tasks; AVFoundation
/// allows responding to it from any thread.
private struct LoadingRequest: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest
    init(_ value: AVAssetResourceLoadingRequest) { self.value = value }
}
