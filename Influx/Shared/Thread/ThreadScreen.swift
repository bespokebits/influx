// A post's thread: the posts it answers above it, then the post, then the
// replies, indented by depth. Opened from the "Replying to" chip or by
// tapping a post; it is fetched when it opens and never stored. It is an
// ordinary SwiftUI list: threads are short, so the timeline's bitmap rows
// aren't needed here.
import SwiftUI
#if os(iOS)
import UIKit
#endif
import InfluxKit

struct ThreadScreen: View {
    let post: Item
    let interactions: RowInteractions
    var close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ThreadPage(post: post, interactions: interactions)
                .navigationDestination(for: Item.self) { ThreadPage(post: $0, interactions: interactions) }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: close)
                            .accessibilityIdentifier("thread-done")
                    }
                }
        }
        // A video played from the thread stops with it.
        .onDisappear { VideoPlayback.stop() }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 520, idealHeight: 720)
        #endif
    }
}

/// One thread, for the post it was opened on. Tapping another post in it
/// opens that post's thread on top.
private struct ThreadPage: View {
    let post: Item
    let interactions: RowInteractions
    @State private var thread: PostThread?
    @State private var failure: String?
    /// The latest state of each post the reader acted on here.
    @State private var viewers: [String: Item.Viewer] = [:]
    /// The posts whose only action is Influx's own bookmark, by merge key:
    /// a rich feed's posts that the store holds (ADR 0031). A rich post
    /// only seen here has no action at all.
    @State private var ownBookmarks: Set<String> = []
    @State private var notice: String?
    @State private var shownImage: ShownImage?

    private struct ShownImage: Identifiable {
        let media: Item.Media
        var id: String { media.url }
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let thread {
                        // Missing posts are noted at the edge of their list,
                        // since a gap doesn't say where in it they fall.
                        if let note = thread.missingNote(at: .ancestors) { ThreadMissingNoteView(note: note, wholeThread: thread.wholeThread) }
                        ForEach(thread.ancestors, id: \.remoteID) { entry(for: $0, depth: 0, isFocus: false) }
                        entry(for: thread.post, depth: 0, isFocus: true).id("focus")
                        ForEach(thread.replies, id: \.item.remoteID) { entry(for: $0.item, depth: $0.depth, isFocus: false) }
                        if let note = thread.missingNote(at: .replies) { ThreadMissingNoteView(note: note, wholeThread: thread.wholeThread) }
                    } else {
                        entry(for: post, depth: 0, isFocus: true).id("focus")
                        if let failure {
                            Text(failure)
                                .font(.callout)
                                .foregroundStyle(Color.paint(Broadsheet.ink2))
                                .padding(20)
                                .accessibilityIdentifier("thread-error")
                        } else {
                            ProgressView().frame(maxWidth: .infinity).padding(24)
                        }
                    }
                }
            }
            .onChange(of: thread?.ancestors.count) { scroller.scrollTo("focus", anchor: .top) }
        }
        .background(Color.paint(Broadsheet.paper))
        .navigationTitle("Thread")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        self.notice = nil
                    }
            }
        }
        .accessibilityIdentifier("thread")
        .task { await load() }
        // Back from a deeper thread page, where the reader may have acted
        // on the same posts: show them as they now stand.
        .onAppear {
            guard let thread else { return }
            let posts = thread.ancestors + [thread.post] + thread.replies.map(\.item)
            Task {
                await findOwnBookmarks(of: posts)
                // A post no action applies to (a rich post) stays without.
                for item in posts where item.viewer != nil && !ownBookmarks.contains(item.mergeKey) {
                    if let viewer = try? await interactions.actions.viewer(of: item) { viewers[item.mergeKey] = viewer }
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $shownImage) { shown in ImageViewer(media: shown.media) { shownImage = nil } }
        #else
        .sheet(item: $shownImage) { shown in ImageViewer(media: shown.media) { shownImage = nil } }
        #endif
    }

    private func entry(for item: Item, depth: Int, isFocus: Bool) -> some View {
        var shown = item
        if let viewer = viewers[item.mergeKey] { shown.viewer = viewer }
        let ownBookmark = ownBookmarks.contains(item.mergeKey)
        // A post opens its own thread only where it has one: on a rich
        // feed, the context around the post names none.
        let opensThread = interactions.connector(forSource: item.sourceID)?.offersThread(of: ItemReference(item)) ?? false
        return ThreadPostView(item: shown, depth: depth, isFocus: isFocus, opensThread: opensThread,
                              actions: ownBookmark ? [.bookmark] : [.boost, .like, .bookmark], open: open) { toggle in
            // Shows the change at once, as the timeline does.
            let viewer = shown.viewer ?? Item.Viewer()
            if viewer.unconfirmed != true { viewers[shown.mergeKey] = viewer.applying(viewer.action(toggle)) }
            Task {
                notice = await interactions.toggle(toggle, on: shown) { viewers[shown.mergeKey] = $0 }
                // Another toggle of this post may have finished, or gone
                // back, meanwhile; show the post as it now stands.
                let viewer: Item.Viewer?
                if ownBookmark {
                    viewer = await interactions.ownBookmark(of: shown)
                } else {
                    viewer = try? await interactions.actions.viewer(of: shown)
                }
                if let viewer { viewers[shown.mergeKey] = viewer }
            }
        }
    }

    /// A video or gif plays as it does from the timeline; an image opens
    /// as large as fits.
    private func open(_ media: Item.Media) {
        if VideoPlayback.canPlay(media) {
            #if os(iOS)
            VideoPlayback.play(media, from: Self.topViewController())
            #else
            VideoPlayback.play(media, from: nil)
            #endif
        } else if media.kind == .image {
            shownImage = ShownImage(media: media)
        }
    }

    #if os(iOS)
    /// What the player goes over: the thread sheet itself.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
    #endif

    /// Finds which of `posts` have Influx's own bookmark, with its state.
    private func findOwnBookmarks(of posts: [Item]) async {
        for item in posts {
            guard let viewer = await interactions.ownBookmark(of: item) else { continue }
            ownBookmarks.insert(item.mergeKey)
            viewers[item.mergeKey] = viewer
        }
    }

    private func load() async {
        await findOwnBookmarks(of: [post])
        guard thread == nil, let connector = interactions.connector(forSource: post.sourceID) else {
            if thread == nil { failure = "Sign in to this account on this device to see the thread." }
            return
        }
        do {
            let loaded = try await interactions.actions.thread(of: post, with: connector)
            await findOwnBookmarks(of: loaded.ancestors + [loaded.post] + loaded.replies.map(\.item))
            thread = loaded
            failure = nil
        } catch {
            failure = switch error {
            case ConnectorError.offline: "Couldn't load the thread: no connection."
            case ConnectorError.notFound: "This post is gone."
            case ConnectorError.unauthorized: "Couldn't load the thread: sign in to this account again."
            default: "Couldn't load the thread."
            }
        }
    }
}

/// One post in a thread, Broadsheet style: author line, serif text with its
/// links, media, and its actions: the three post actions, or only the
/// bookmark for a post whose bookmark Influx keeps.
private struct ThreadPostView: View {
    let item: Item
    let depth: Int
    let isFocus: Bool
    /// Whether tapping the post opens its own thread on top.
    let opensThread: Bool
    /// The icons under the post, shown when it has viewer state.
    let actions: [RowAction]
    let open: (Item.Media) -> Void
    let toggle: (Item.Viewer.Toggle) -> Void

    /// Replies nest, but never so deep the text gets too narrow to read.
    private var indent: CGFloat { CGFloat(min(depth, 4)) * 16 }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.authorName).fontWeight(.medium).foregroundStyle(Color.paint(Broadsheet.ink))
                Text("\(item.authorHandle) · \(item.publishedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .foregroundStyle(Color.paint(Broadsheet.ink2))
                    .lineLimit(1)
            }
            .font(.caption)
            Text(Self.attributedBody(item))
                .font(.system(isFocus ? .title3 : .body, design: .serif))
                .foregroundStyle(Color.paint(Broadsheet.ink))
                .tint(Color.paint(Broadsheet.ink))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let card = item.linkCard, let url = URL(string: card.url) {
                Link(destination: url) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.site.uppercased()).font(.caption2).foregroundStyle(Color.paint(Broadsheet.ink2))
                        Text(card.title).font(.system(.subheadline, design: .serif)).foregroundStyle(Color.paint(Broadsheet.ink))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.paint(Broadsheet.wash))
                }
            }
            ForEach(Array(item.media.prefix(4).enumerated()), id: \.offset) { _, media in
                Button { open(media) } label: { RemoteImage(media: media) }
                    .buttonStyle(.plain)
            }
            if let quote = item.quote {
                ThreadQuoteCard(quote: quote).padding(.top, 4)
            }
            if let viewer = item.viewer {
                HStack(spacing: 28) {
                    ForEach(actions, id: \.self) { action in
                        let (name, on) = RowText.symbol(action, viewer)
                        Button {
                            if let toggle = action.toggle { self.toggle(toggle) }
                        } label: {
                            Image(systemName: name)
                                .foregroundStyle(Color.paint(on ? (action == .like ? Broadsheet.liked : action == .boost ? Broadsheet.boosted : Broadsheet.ink) : Broadsheet.ink2))
                                .frame(minWidth: 32, minHeight: 32, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(RowText.actionName(action, viewer))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.leading, 20 + indent)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isFocus ? Color.paint(Broadsheet.wash).opacity(0.5) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.paint(Broadsheet.rule)).frame(height: 1).padding(.horizontal, 20)
        }
        .overlay(alignment: .leading) {
            if depth > 0 {
                Rectangle().fill(Color.paint(Broadsheet.rule)).frame(width: 1).padding(.leading, 12 + indent - 8)
            }
        }

        if isFocus || !opensThread {
            content
        } else {
            NavigationLink(value: item) { content }
                .buttonStyle(.plain)
        }
    }

    /// The body with its links made tappable.
    static func attributedBody(_ item: Item) -> AttributedString {
        let string = NSMutableAttributedString(string: item.body)
        for link in item.links {
            guard link.start >= 0, link.start + link.length <= string.length, let url = URL(string: link.url) else { continue }
            string.addAttribute(.link, value: url, range: NSRange(location: link.start, length: link.length))
        }
        return AttributedString(string)
    }
}

/// What a thread says where posts are missing from it: a note on the wash
/// colour with a heading, a sentence per reason, and a way to the whole
/// thread on its own site (#234).
struct ThreadMissingNoteView: View {
    let note: PostThread.MissingNote
    let wholeThread: (url: URL, site: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.heading)
                .textCase(.uppercase)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.paint(Broadsheet.ink2))
                .accessibilityAddTraits(.isHeader)
            ForEach(note.sentences, id: \.self) { sentence in
                Text(sentence)
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(Color.paint(Broadsheet.ink))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let wholeThread {
                Link(destination: wholeThread.url) {
                    Text("Read the whole thread on \(wholeThread.site) \(Image(systemName: "arrow.up.right"))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.paint(Broadsheet.ink))
                        .underline()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Read the whole thread on \(wholeThread.site)")
                .accessibilityIdentifier("thread-whole-\(note.position.rawValue)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.paint(Broadsheet.wash))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread-missing-\(note.position.rawValue)")
    }
}

/// A quoted post in a thread, as the timeline's quote card draws it: a
/// hairline box with its picture, "name  @handle", its text and its site,
/// opening the quoted post. An unavailable quote keeps the box and says so
/// in one italic line over its site, each line cut short.
struct ThreadQuoteCard: View {
    let quote: Item.Quote

    var body: some View {
        if let url = quote.url.flatMap({ URL(string: $0) }) {
            Link(destination: url) { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !quote.isUnavailable, let image = quote.image {
                RemoteImage(media: image, maxHeight: 280)
            }
            VStack(alignment: .leading, spacing: 4) {
                if quote.isUnavailable {
                    Text(RowText.quoteUnavailableText)
                        .font(.system(.subheadline, design: .serif).italic())
                        .foregroundStyle(Color.paint(Broadsheet.ink2))
                        .lineLimit(1)
                } else {
                    Text("\(Text(quote.authorName).foregroundStyle(Color.paint(Broadsheet.ink)))  \(Text(quote.authorHandle).foregroundStyle(Color.paint(Broadsheet.ink2)))")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    let body = quote.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        Text(body)
                            .font(.system(.subheadline, design: .serif))
                            .foregroundStyle(Color.paint(Broadsheet.ink))
                            .lineLimit(Int(RowLayout.quoteBodyLines))
                            .multilineTextAlignment(.leading)
                    }
                }
                if let site = RowText.site(of: quote) {
                    Text(site).font(.caption).foregroundStyle(Color.paint(Broadsheet.ink2)).lineLimit(1)
                }
            }
            .padding(10)
        }
        .frame(maxWidth: RowLayout.mediaMaxWidth, alignment: .leading)
        .overlay { Rectangle().strokeBorder(Color.paint(Broadsheet.rule), lineWidth: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quote.isUnavailable ? RowText.quoteUnavailableLabel(quote) : Self.label(quote))
        .accessibilityIdentifier(quote.isUnavailable ? "thread-quote-unavailable" : "thread-quote")
    }

    private static func label(_ quote: Item.Quote) -> String {
        let body = quote.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "Quoting \(quote.authorName)" : "Quoting \(quote.authorName): \(body)"
    }
}

/// An image or a video's still, loaded at the size it is shown through the
/// pinned media loader, with its box sized before it loads. In `.fill`
/// mode it fills its box (a thread's tiles); in `.fit` mode the whole
/// image shows, as large as fits (the image viewer).
struct RemoteImage: View {
    let media: Item.Media
    var maxHeight: CGFloat = 420
    var contentMode: ContentMode = .fill
    /// The longest side to decode at; by default enough for `maxHeight`.
    var pixels: Int?
    @State private var image: CGImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        let aspect = CGFloat(media.aspect)
        // The overlays sit on the aspect-shaped box, before it is framed,
        // so the image is cut to the image's own shape and never to the
        // wider frame around it.
        Color.paint(Broadsheet.wash)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: scale).resizable().aspectRatio(contentMode: contentMode)
                }
            }
            .overlay {
                if media.kind != .image {
                    Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.85))
                }
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
            .accessibilityLabel(media.altText ?? (media.kind == .image ? "Image" : "Video"))
            .task(id: media.url) {
                guard let url = media.kind == .image ? media.url : media.previewURL else { return }
                let request = MediaRequest(url: url, pixels: pixels ?? Int((maxHeight * max(aspect, 1) * scale).rounded()))
                if await MediaImages.shared.load(request) {
                    image = MediaImages.shared.image(for: request)
                }
            }
    }
}

/// An image opened from the timeline: all of it, as large as fits.
struct ImageViewer: View {
    let media: Item.Media
    var close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            // Decoded at its own size (within the decode budget), so text in
            // a screenshot stays sharp at full screen.
            RemoteImage(media: media, maxHeight: .infinity, contentMode: .fit,
                        pixels: MediaGrid.largestDecode(pixelWidth: media.width, pixelHeight: media.height))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button("Done", action: close)
                .buttonStyle(.glass)
                .padding(16)
                .accessibilityIdentifier("image-done")
        }
        .onTapGesture(perform: close)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: Self.idealSize(media).width, minHeight: 360, idealHeight: Self.idealSize(media).height)
        #endif
    }

    #if os(macOS)
    /// The window's first size: the image's own shape, at most 1100 by 800
    /// points, so a tall or wide image isn't letterboxed in a fixed window.
    static func idealSize(_ media: Item.Media) -> CGSize {
        let fit = min(1100 / CGFloat(media.width), 800 / CGFloat(media.height), 1)
        return CGSize(width: max(480, CGFloat(media.width) * fit), height: max(360, CGFloat(media.height) * fit))
    }
    #endif
}

