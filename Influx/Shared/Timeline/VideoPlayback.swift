// Which videos play, and playing one through the InfluxVideo framework, which
// the app loads on the first tap so AVFoundation and AVKit stay out of
// launch. The player itself is in Influx/Video/InfluxVideo.swift.
//
// A video's address comes from someone's post, so it is fetched like an
// image: a movie file through MediaResolver's pinned fetch, which only
// reaches public addresses. An HLS stream fetches its own playlists and
// segments, which no loader can check, so streams play only from the
// services' own video servers (`streamHosts`). A rich post's video or GIF
// is a reference (SammyMediaReference), read in pieces through its
// account's grants, which renew themselves as playback asks for more.
import Foundation
import InfluxKit

@MainActor
enum VideoPlayback {
    /// Hosts whose HLS streams play: Bluesky's video service and its CDN.
    nonisolated static let streamHosts: Set<String> = ["video.bsky.app", "video.cdn.bsky.app"]

    /// Whether tapping `media` plays it: https videos and gifs (services send
    /// gifs as short videos), and streams only from `streamHosts`. An actual
    /// GIF file isn't something AVPlayer plays, so it stays a still.
    nonisolated static func canPlay(_ media: Item.Media) -> Bool {
        guard media.kind != .image else { return false }
        if SammyMediaReference(media.url) != nil { return true }
        guard let url = URL(string: media.url), url.scheme == "https" else { return false }
        let path = url.path.lowercased()
        if path.hasSuffix(".gif") { return false }
        if isStream(url) { return url.host().map { streamHosts.contains($0.lowercased()) } ?? false }
        return true
    }

    nonisolated static func isStream(_ url: URL) -> Bool {
        url.path.lowercased().hasSuffix(".m3u8")
    }

    /// Plays `media`: full screen over `presenter` on iOS, in the player
    /// window on macOS (pass nil). False when it can't play.
    @discardableResult
    static func play(_ media: Item.Media, from presenter: NSObject?) -> Bool {
        guard canPlay(media), let url = URL(string: media.url), let play = loadedPlay() else { return false }
        if let reference = SammyMediaReference(media.url) {
            let images = MediaImages.shared
            let fetch: Fetch = { _, lower, upper, limit, timeout, done in
                Task {
                    let response = try? await images.grants(for: reference)?
                        .fetch(reference, bytes: lower...upper, upTo: limit, timeout: .seconds(timeout))
                    done(response?.statusCode ?? 0, response?.totalLength ?? -1,
                         response?.contentType as NSString?, response?.data as NSData?)
                }
            }
            return play(presenter, media.url as NSString, media.kind == .gif, false, media.aspect, fetch)
        }
        let resolver = MediaImages.shared.resolver
        let fetch: Fetch = { source, lower, upper, limit, timeout, done in
            let source = source as String
            Task {
                let response = await resolver.fetch(source, bytes: lower...upper, upTo: limit, timeout: .seconds(timeout))
                done(response?.statusCode ?? 0, response?.totalLength ?? -1,
                     response?.contentType as NSString?, response?.data as NSData?)
            }
        }
        return play(presenter, media.url as NSString, media.kind == .gif, isStream(url), media.aspect, fetch)
    }

    /// Stops the video playing now, if one was ever played.
    static func stop() {
        guard didLoad, let address = EmbeddedFramework.symbol("influx_video_stop", in: "InfluxVideo") else { return }
        unsafeBitCast(address, to: Stop.self)()
    }

    // The entry points in InfluxVideo.swift, with its block types.
    private typealias Fetched = @Sendable @convention(block) (Int, Int, NSString?, NSData?) -> Void
    private typealias Fetch = @Sendable @convention(block) (NSString, Int, Int, Int, Double, @escaping Fetched) -> Void
    private typealias Play = @convention(c) (NSObject?, NSString, Bool, Bool, Double, @escaping Fetch) -> Bool
    private typealias Stop = @convention(c) () -> Void

    private static var didLoad = false

    private static func loadedPlay() -> Play? {
        guard let address = EmbeddedFramework.symbol("influx_video_play", in: "InfluxVideo") else { return nil }
        didLoad = true
        return unsafeBitCast(address, to: Play.self)
    }
}
