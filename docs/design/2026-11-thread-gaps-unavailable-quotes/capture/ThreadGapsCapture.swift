// Captures the thread view and quoting timeline rows for the design review
// in this folder: what ships today, and three treatments each for a thread
// with missing posts and for a quote of an unavailable post.
//
// Not part of the test suite. For a capture run, copy this file into
// `InfluxTests/`, apply `sample-connector.patch`, run the app tests for the
// platform, collect the pictures from the folder it prints, then delete
// the copy and revert the patch (see ../README.md).
//
// What ships today is drawn by the app's own code: the timeline rows by
// `RowLayout` and `RowRenderer` (the bitmaps the timeline's cells show),
// the thread by `ThreadScreen` over the sample connector, which the patch
// lets this file hand a thread. The treatments are mock-ups: a row is the
// app's own bitmap with room made for the new box, which is drawn here in
// the same fonts and colours; a thread is a copy of the thread view's
// layout with the new parts added. Nothing here reaches the network. On
// the Mac every picture is drawn in this process: nothing here captures
// the screen or a window, and nothing may, since that asks the person at
// the Mac for screen recording.
import Foundation
import ImageIO
import InfluxKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Influx
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Made-up content

private enum Fixture {
    static let source = "capture-feed"
    static let start = Date(timeIntervalSince1970: 1_794_200_000)

    static func post(_ id: String, _ name: String, _ handle: String, _ body: String, minutes: Int,
                     quote: Item.Quote? = nil, viewer: Item.Viewer? = nil) -> Item {
        Item(sourceID: source, remoteID: id, kind: .post, mergeKey: "https://example.com/posts/\(id)",
             authorName: name, authorHandle: handle, body: body, url: "https://example.com/posts/\(id)",
             publishedAt: start.addingTimeInterval(Double(minutes) * 60), fetchedAt: start,
             quote: quote, viewer: viewer)
    }

    static let iris = ("Iris Calder", "@iris@example.com")
    static let tomas = ("Tomas Reyes", "@tomas@example.net")
    static let mira = ("Mira Okonkwo", "@mira@example.org")

    /// A quote the source could show.
    static let trustQuote = Item.Quote(
        mergeKey: "https://example.org/@trust/2001", url: "https://example.org/@trust/2001",
        authorName: "Riverside Trust", authorHandle: "@trust@example.org",
        body: "The boardwalk works finish this week. Thank you for your patience while the path is rebuilt."
    )
    /// A quote the source can't show: all the reader gets is its address.
    static let goneQuoteURL = "https://example.com/@notices/1134028"

    /// A conversation with posts above the opened one and the author's own
    /// continuations below it.
    static func gapThread(_ gaps: [PostThread.Gap]) -> PostThread {
        PostThread(
            ancestors: [
                post("a1", iris.0, iris.1, "The river path reopens on Saturday after the flood repairs. Has anyone walked the new section?", minutes: 0),
                post("a2", tomas.0, tomas.1, "I went this morning. The boardwalk past the mill is finished; the far end is still gravel.", minutes: 25),
            ],
            post: post("f", mira.0, mira.1, "Walked it at dawn. The new boardwalk is lovely, and the herons are back by the weir.", minutes: 70),
            replies: [
                .init(item: post("c1", mira.0, mira.1, "The gravel stretch is fine on foot but rough on a bike. From the mill bridge, the road is the better ride.", minutes: 72), depth: 1),
                .init(item: post("c2", mira.0, mira.1, "And the café at the lock is open again, with its old hours.", minutes: 74), depth: 1),
            ],
            gaps: gaps
        )
    }

    /// A thread whose opened post quotes one that is gone, and whose
    /// parent quotes one that is still there.
    static let quoteThread = PostThread(
        ancestors: [post("q1", tomas.0, tomas.1, "Good news for weekend walks.", minutes: 0, quote: trustQuote)],
        post: post("q2", mira.0, mira.1, "Does anyone have the new closure notice? The one I quoted last week has gone.", minutes: 40),
        replies: [.init(item: post("q3", mira.0, mira.1, "Found it on the board by the lock: the path stays open through December.", minutes: 55), depth: 1)]
    )
    /// Which posts quote a post that is unavailable, and its address. The
    /// app keeps no such quote today, so the fixture carries it alongside.
    static let unavailableQuotes = ["q2": goneQuoteURL]

    /// Two timeline posts: one quoting a post that is there, one quoting
    /// a post that is gone (which the app stores without a quote).
    static let rowPosts = [
        post("r1", tomas.0, tomas.1, "Good news for weekend walks.", minutes: 0, quote: trustQuote, viewer: Item.Viewer()),
        post("r2", mira.0, mira.1, "Does anyone have the new closure notice? The one I quoted last week has gone.", minutes: 40, viewer: Item.Viewer()),
    ]

    /// Each picture of a thread with missing posts: its name and its gaps.
    static let gapCases: [(String, [PostThread.Gap])] = [
        ("deleted", [.init(position: .ancestors, reason: .deleted), .init(position: .replies, reason: .deleted)]),
        ("unavailable", [.init(position: .ancestors, reason: .unavailable), .init(position: .replies, reason: .unavailable)]),
        ("not-collected", [.init(position: .ancestors, reason: .notCollected), .init(position: .replies, reason: .notCollected)]),
        ("two-reasons", [.init(position: .ancestors, reason: .deleted), .init(position: .ancestors, reason: .unavailable)]),
    ]
}

// MARK: - The words

/// The three treatments, shared by both surfaces: a quiet line of text, a
/// hairline frame, and a washed note.
private enum Treatment: String, CaseIterable {
    case A, B, C
}

private enum Words {
    /// One sentence per gap, for the quiet line.
    static func sentence(_ gap: PostThread.Gap) -> String {
        switch (gap.position, gap.reason) {
        case (.ancestors, .deleted): "Some earlier posts were deleted by their authors."
        case (.ancestors, .unavailable): "Some earlier posts are private, blocked or unreachable."
        case (.ancestors, .notCollected): "The conversation starts further back than was collected."
        case (.replies, .deleted): "Some later posts were deleted by their author."
        case (.replies, .unavailable): "Some later posts are private, blocked or unreachable."
        case (.replies, .notCollected): "The thread goes on past what was collected."
        case (.ancestors, .other): "Some earlier posts are missing."
        case (.replies, .other): "Some later posts are missing."
        }
    }

    /// A short title and a line of detail, for the frame.
    static func title(_ gap: PostThread.Gap) -> String {
        let which = gap.position == .ancestors ? "Earlier" : "Later"
        return switch gap.reason {
        case .deleted: "\(which) posts deleted"
        case .unavailable: "\(which) posts can't be shown"
        case .notCollected: "\(which) posts not collected"
        case .other: "\(which) posts missing"
        }
    }

    static func detail(_ gap: PostThread.Gap) -> String {
        switch gap.reason {
        case .deleted: gap.position == .ancestors ? "Removed by their authors." : "Removed by the author."
        case .unavailable: "Private, blocked or unreachable."
        case .notCollected: gap.position == .ancestors ? "The conversation starts further back." : "The thread goes on past this."
        case .other: "Missing for a reason this version doesn't know."
        }
    }

    static func symbol(_ reason: PostThread.Gap.Reason) -> String {
        switch reason {
        case .deleted: "trash"
        case .unavailable: "eye.slash"
        case .notCollected: "ellipsis"
        case .other: "questionmark"
        }
    }

    static func host(_ url: String) -> String {
        var host = URL(string: url)?.host() ?? url
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The address without its scheme: host and path.
    static func address(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        return host(url) + parsed.path()
    }
}

private let ink = Color.paint(Broadsheet.ink)
private let ink2 = Color.paint(Broadsheet.ink2)
private let rule = Color.paint(Broadsheet.rule)
private let wash = Color.paint(Broadsheet.wash)
private let paper = Color.paint(Broadsheet.paper)

// MARK: - Thread view mock-ups (SwiftUI)

/// The thread view's own frame, as `ThreadScreen` has it: a navigation
/// stack titled Thread with Done, over paper.
private struct MockThreadScreen: View {
    let thread: PostThread
    var gaps: Treatment?
    var quotes: Treatment?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let gaps { gapMarker(.ancestors, gaps) }
                    ForEach(thread.ancestors, id: \.remoteID) { MockThreadPost(item: $0, depth: 0, isFocus: false, quotes: quotes) }
                    MockThreadPost(item: thread.post, depth: 0, isFocus: true, quotes: quotes)
                    ForEach(thread.replies, id: \.item.remoteID) { MockThreadPost(item: $0.item, depth: $0.depth, isFocus: false, quotes: quotes) }
                    if let gaps { gapMarker(.replies, gaps) }
                }
            }
            .background(paper)
            .navigationTitle("Thread")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") {} }
            }
        }
    }

    @ViewBuilder
    private func gapMarker(_ position: PostThread.Gap.Position, _ treatment: Treatment) -> some View {
        let here = thread.gaps.filter { $0.position == position }
        if !here.isEmpty {
            GapMarker(gaps: here, position: position, treatment: treatment, original: thread.post.url.flatMap(URL.init(string:)))
        }
    }
}

/// What a thread shows where posts are missing: above the first earlier
/// post, or below the last later one, since a gap doesn't say where in its
/// list it falls.
private struct GapMarker: View {
    let gaps: [PostThread.Gap]
    let position: PostThread.Gap.Position
    let treatment: Treatment
    let original: URL?

    var body: some View {
        switch treatment {
        case .A: quietLine
        case .B: frames
        case .C: note
        }
    }

    /// A: a line of italic text per reason, with an ellipsis, between rules.
    private var quietLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(gaps, id: \.self) { gap in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "ellipsis").font(.caption)
                    Text(Words.sentence(gap)).font(.system(.footnote, design: .serif).italic())
                }
            }
        }
        .foregroundStyle(ink2)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(rule).frame(height: 1).padding(.horizontal, 20) }
    }

    /// B: a dashed hairline frame per reason, where a post would be.
    private var frames: some View {
        VStack(spacing: 8) {
            ForEach(gaps, id: \.self) { gap in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: Words.symbol(gap.reason))
                        .font(.footnote)
                        .foregroundStyle(ink2)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Words.title(gap)).font(.caption.weight(.medium)).foregroundStyle(ink)
                        Text(Words.detail(gap)).font(.footnote).foregroundStyle(ink2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay { Rectangle().strokeBorder(rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(rule).frame(height: 1).padding(.horizontal, 20) }
    }

    /// C: a washed note across the thread, with a way to the whole
    /// conversation on its own site.
    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(position == .ancestors ? "EARLIER POSTS MISSING" : "LATER POSTS MISSING")
                .font(.caption2.weight(.medium))
                .foregroundStyle(ink2)
            ForEach(gaps, id: \.self) { gap in
                Text(Words.sentence(gap))
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(ink)
            }
            if let original {
                Text("Read the whole thread on \(Words.host(original.absoluteString)) \(Image(systemName: "arrow.up.right"))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ink)
                    .underline()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wash)
    }
}

/// `ThreadPostView` as the app draws it (at 521082c), with a quote card
/// added after the media: the app's thread view has none today.
private struct MockThreadPost: View {
    let item: Item
    let depth: Int
    let isFocus: Bool
    let quotes: Treatment?

    private var indent: CGFloat { CGFloat(min(depth, 4)) * 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.authorName).fontWeight(.medium).foregroundStyle(ink)
                Text("\(item.authorHandle) · \(item.publishedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .foregroundStyle(ink2)
                    .lineLimit(1)
            }
            .font(.caption)
            Text(item.body)
                .font(.system(isFocus ? .title3 : .body, design: .serif))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
            if let quotes {
                if let quote = item.quote {
                    QuoteCard(quote: quote).padding(.top, 4)
                } else if let url = Fixture.unavailableQuotes[item.remoteID] {
                    UnavailableQuote(url: url, treatment: quotes).padding(.top, 4)
                }
            }
        }
        .padding(.leading, 20 + indent)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isFocus ? wash.opacity(0.5) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(rule).frame(height: 1).padding(.horizontal, 20) }
        .overlay(alignment: .leading) {
            if depth > 0 { Rectangle().fill(rule).frame(width: 1).padding(.leading, 12 + indent - 8) }
        }
    }
}

/// The timeline's quote card in SwiftUI: a hairline box with the quoted
/// post's author, text and site.
private struct QuoteCard: View {
    let quote: Item.Quote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Text(quote.authorName).foregroundStyle(ink))  \(Text(quote.authorHandle).foregroundStyle(ink2))")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(quote.body)
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(ink)
                .lineLimit(6)
            if let url = quote.url {
                Text(Words.host(url)).font(.caption).foregroundStyle(ink2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { Rectangle().strokeBorder(rule, lineWidth: 1) }
    }
}

/// A quote of a post that is unavailable, in each treatment. Every line
/// is a single line, so its height never depends on what it says.
private struct UnavailableQuote: View {
    let url: String
    let treatment: Treatment

    var body: some View {
        switch treatment {
        case .A:
            Text("Quoted post unavailable · \(Text(Words.host(url)).underline())")
                .font(.caption)
                .foregroundStyle(ink2)
                .lineLimit(1)
        case .B:
            VStack(alignment: .leading, spacing: 4) {
                Text("The quoted post is unavailable.")
                    .font(.system(.subheadline, design: .serif).italic())
                    .foregroundStyle(ink2)
                    .lineLimit(1)
                Text(Words.host(url)).font(.caption).foregroundStyle(ink2).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay { Rectangle().strokeBorder(rule, lineWidth: 1) }
        case .C:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "eye.slash").font(.caption).foregroundStyle(ink2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quoted post unavailable").font(.caption.weight(.medium)).foregroundStyle(ink).lineLimit(1)
                    Text(Words.address(url)).font(.caption).foregroundStyle(ink2).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(wash)
        }
    }
}

// MARK: - Timeline row mock-ups (bitmaps)

/// The box for an unavailable quote in a timeline row, drawn into the
/// row's bitmap like the quote card. Its height is fixed by the type size
/// alone: every line is one line, cut short rather than wrapped.
private enum RowSlip {
    static let padding = RowLayout.linkPadding

    static func italic(_ font: PlatformFont) -> PlatformFont {
        #if canImport(UIKit)
        font.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        #else
        NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
        #endif
    }

    static func height(_ treatment: Treatment, _ type: Typography) -> CGFloat {
        let meta = Broadsheet.lineHeight(type.meta)
        return switch treatment {
        case .A: meta
        case .B: (padding * 2 + Broadsheet.lineHeight(italic(type.linkSummary)) + 2 + meta).rounded(.up)
        case .C: (padding * 2 + meta * 2 + 2).rounded(.up)
        }
    }

    static func line(_ string: String, _ font: PlatformFont, _ color: PlatformColor, breaking: NSLineBreakMode = .byTruncatingTail,
                     underline: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = breaking
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = Broadsheet.ink2
        }
        return NSAttributedString(string: string, attributes: attributes)
    }

    static func draw(_ treatment: Treatment, url: String, in frame: CGRect, type: Typography, scale: CGFloat, context: CGContext) {
        let meta = Broadsheet.lineHeight(type.meta)
        let hairline = 1 / scale
        func text(_ string: NSAttributedString, _ rect: CGRect) {
            string.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        }
        switch treatment {
        case .A:
            let words = NSMutableAttributedString(attributedString: line("Quoted post unavailable · ", type.meta, Broadsheet.ink2))
            words.append(line(Words.host(url), type.meta, Broadsheet.ink2, underline: true))
            text(words, frame)
        case .B:
            context.setStrokeColor(Broadsheet.rule.cgColor)
            context.setLineWidth(hairline)
            context.stroke(frame.insetBy(dx: hairline / 2, dy: hairline / 2))
            let font = italic(type.linkSummary)
            let inner = frame.insetBy(dx: padding, dy: padding)
            let first = Broadsheet.lineHeight(font)
            text(line("The quoted post is unavailable.", font, Broadsheet.ink2), CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: first))
            text(line(Words.host(url), type.meta, Broadsheet.ink2), CGRect(x: inner.minX, y: inner.minY + first + 2, width: inner.width, height: meta))
        case .C:
            context.setFillColor(Broadsheet.wash.cgColor)
            context.fill(frame)
            let inner = frame.insetBy(dx: padding, dy: padding)
            let icon = CGRect(x: inner.minX, y: inner.minY, width: meta, height: meta)
            symbol("eye.slash", color: Broadsheet.ink2, in: icon, scale: scale, context: context)
            let x = icon.maxX + 6
            text(line("Quoted post unavailable", type.meta, Broadsheet.ink), CGRect(x: x, y: inner.minY, width: inner.maxX - x, height: meta))
            text(line(Words.address(url), type.meta, Broadsheet.ink2, breaking: .byTruncatingMiddle),
                 CGRect(x: x, y: inner.minY + meta + 2, width: inner.maxX - x, height: meta))
        }
    }

    /// As `RowRenderer` draws its icons: from `SymbolImages`, fitted and
    /// centred in `frame`.
    static func symbol(_ name: String, color: PlatformColor, in frame: CGRect, scale: CGFloat, context: CGContext) {
        guard let symbol = SymbolImages.shared.image(name, color: color.cgColor, pointSize: frame.height * 0.82, scale: scale)
        else { return }
        let fit = min(frame.width / symbol.size.width, frame.height / symbol.size.height, 1)
        let width = symbol.size.width * fit, height = symbol.size.height * fit
        let target = CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        context.saveGState()
        context.translateBy(x: 0, y: target.minY + target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(symbol.image, in: target)
        context.restoreGState()
    }
}

/// A row as the timeline draws it. With a treatment, the row's geometry
/// makes room for the box where a quote card goes (after the text and
/// media, before the icons), the app draws the row around it, and the box
/// is drawn into the gap.
@MainActor
private func rowImage(_ row: TimelineRow, treatment: Treatment?, in environment: RowEnvironment) throws -> CGImage {
    var geometry = RowLayout.geometry(for: row, in: environment)
    var box: CGRect?
    if let treatment {
        let type = environment.typography
        let height = RowSlip.height(treatment, type)
        let top = geometry.actions.first.map { $0.minY - RowLayout.actionGap } ?? geometry.body.maxY
        let added = RowLayout.gap + 4 + height
        box = CGRect(x: geometry.body.minX, y: top + RowLayout.gap + 4,
                     width: min(geometry.body.width, RowLayout.mediaMaxWidth), height: height)
        geometry.actions = geometry.actions.map { $0.offsetBy(dx: 0, dy: added) }
        geometry.height = ceil(geometry.height + added)
    }
    let drawn = try #require(RowRenderer.render(row, geometry: geometry, in: environment)).image
    guard let box, let treatment else { return drawn }
    return try #require(drawOver(drawn, environment) { context in
        RowSlip.draw(treatment, url: Fixture.goneQuoteURL, in: box, type: environment.typography, scale: environment.scale, context: context)
    })
}

/// `image` with more drawn over it, in points from the top left, in the
/// appearance the row was drawn in, as `RowRenderer` sets it up.
private func drawOver(_ image: CGImage, _ environment: RowEnvironment, _ body: (CGContext) -> Void) -> CGImage? {
    let width = image.width, height = image.height
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: environment.scale, y: -environment.scale)
    #if canImport(UIKit)
    UIGraphicsPushContext(context)
    UITraitCollection(userInterfaceStyle: environment.dark ? .dark : .light).performAsCurrent { body(context) }
    UIGraphicsPopContext()
    #else
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    NSAppearance(named: environment.dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { body(context) }
    NSGraphicsContext.current = previous
    #endif
    return context.makeImage()
}

/// Rows one above the other, as the timeline shows them.
private func stacked(_ images: [CGImage]) -> CGImage? {
    let width = images.map(\.width).max() ?? 0
    let height = images.map(\.height).reduce(0, +)
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    var top = height
    for image in images {
        top -= image.height
        context.draw(image, in: CGRect(x: 0, y: top, width: image.width, height: image.height))
    }
    return context.makeImage()
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

// MARK: - The capture

@MainActor
@Test func captureThreadGapsAndUnavailableQuotes() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "thread-gaps-capture")
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    print("thread gaps capture: \(folder.path)")

    // Timeline rows, from a store as the timeline reads them.
    let store = try InfluxStore.inMemory()
    try await store.save(sources: [Source(id: Fixture.source, kind: .mastodonHome, accountID: "capture", title: "Home", colorIndex: 0)])
    _ = try await store.insert(Fixture.rowPosts)
    let rows = try await store.rows()
    let quoting = try #require(rows.first { $0.remoteIDSuffix == "r1" })
    let unavailable = try #require(rows.first { $0.remoteIDSuffix == "r2" })

    // The real thread view reads its thread through the sample connector.
    UserDefaults.standard.set(true, forKey: "InfluxSeedTimeline")
    defer {
        UserDefaults.standard.removeObject(forKey: "InfluxSeedTimeline")
        SampleConnector.captureThread = nil
    }
    let app = AppModel.sample(count: 1)
    let interactions = RowInteractions(app: app)

    let platform = platformName
    for dark in [false, true] {
        let look = dark ? "dark" : "light"
        let environment = rowEnvironment(dark: dark)

        // The row surface.
        for treatment in [nil] + Treatment.allCases.map(Optional.some) {
            let pair = [try rowImage(quoting, treatment: nil, in: environment),
                        try rowImage(unavailable, treatment: treatment, in: environment)]
            let image = try #require(stacked(pair))
            try writePNG(image, to: folder.appending(path: "\(platform)-row-\(treatment?.rawValue ?? "current")-\(look).png"))
        }

        // The thread with missing posts.
        for (name, gaps) in Fixture.gapCases {
            let thread = Fixture.gapThread(gaps)
            // The app draws no gap, so its thread looks the same for every
            // case: it is captured once, for the first.
            if name == Fixture.gapCases[0].0 {
                SampleConnector.captureThread = thread
                try await shoot(AnyView(ThreadScreen(post: thread.post, interactions: interactions) {}), dark: dark,
                                to: folder.appending(path: "\(platform)-gaps-current-\(name)-\(look).png"))
            }
            for treatment in Treatment.allCases {
                try await shoot(AnyView(MockThreadScreen(thread: thread, gaps: treatment)), dark: dark,
                                to: folder.appending(path: "\(platform)-gaps-\(treatment.rawValue)-\(name)-\(look).png"))
            }
        }

        // The thread with an unavailable quote.
        SampleConnector.captureThread = Fixture.quoteThread
        try await shoot(AnyView(ThreadScreen(post: Fixture.quoteThread.post, interactions: interactions) {}), dark: dark,
                        to: folder.appending(path: "\(platform)-thread-quote-current-\(look).png"))
        for treatment in Treatment.allCases {
            try await shoot(AnyView(MockThreadScreen(thread: Fixture.quoteThread, quotes: treatment)), dark: dark,
                            to: folder.appending(path: "\(platform)-thread-quote-\(treatment.rawValue)-\(look).png"))
        }
    }
    try "done\n".write(to: folder.appending(path: "status.txt"), atomically: true, encoding: .utf8)
}

private extension TimelineRow {
    /// The fixture's own name for the post, the end of its address.
    var remoteIDSuffix: String { mergeKey.components(separatedBy: "/").last ?? "" }
}

#if canImport(UIKit)

private let platformName = "ios"

@MainActor
private var captureWindow: UIWindow?

@MainActor
private func window() throws -> UIWindow {
    if let captureWindow { return captureWindow }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = try #require(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    root.view.backgroundColor = Broadsheet.paper
    window.rootViewController = root
    window.makeKeyAndVisible()
    captureWindow = window
    return window
}

@MainActor
private func rowEnvironment(dark: Bool) -> RowEnvironment {
    let width = (try? window().bounds.width) ?? 402
    let scale = (try? window().screen.scale) ?? 3
    return RowEnvironment(width: width, scale: scale, dark: dark, typography: Typography(scale: 1))
}

/// `view` in a page sheet over paper, as the timeline opens a thread, and
/// the window as the render server draws it.
@MainActor
private func shoot(_ view: AnyView, dark: Bool, to url: URL) async throws {
    let window = try window()
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    let root = try #require(window.rootViewController)
    let host = UIHostingController(rootView: view)
    host.modalPresentationStyle = .pageSheet
    root.present(host, animated: false)
    // Long enough for the thread to load and lay out.
    try await Task.sleep(for: .seconds(2))
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    try #require(image.pngData()).write(to: url)
    root.dismiss(animated: false)
    try await Task.sleep(for: .milliseconds(500))
}

#else

private let platformName = "mac"

@MainActor
private func rowEnvironment(dark: Bool) -> RowEnvironment {
    RowEnvironment(width: 640, scale: 2, dark: dark, typography: Typography(scale: 1))
}

/// `view` at the thread sheet's ideal size (560 by 720), drawn in this process from
/// the view itself. The sheet's title bar and Done button are the
/// window's, so they aren't in the picture.
@MainActor
private func shoot(_ view: AnyView, dark: Bool, to url: URL) async throws {
    let size = NSSize(width: 560, height: 720)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = hosting
    window.orderFrontRegardless()
    try await Task.sleep(for: .seconds(2))
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    window.close()
}

#endif
