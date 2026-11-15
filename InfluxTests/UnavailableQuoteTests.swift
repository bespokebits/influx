import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import InfluxKit
@testable import Influx

/// A quote of a post the source can't show (#234): in a row, the quote
/// card's hairline box with one italic line and the site, at a height the
/// text size alone sets, drawn into the row's bitmap; in a thread, the same
/// box beside the ordinary quote card, and a note where posts are missing.
@Suite struct UnavailableQuotes {
    private let environment = RowEnvironment(width: 390, scale: 3, dark: false, typography: Typography(scale: 1))

    private func row(_ quote: Item.Quote?) async throws -> TimelineRow {
        let item = Item(sourceID: "m", remoteID: "1", kind: .post, mergeKey: "https://example.social/1",
                        authorName: "Mira Okonkwo", authorHandle: "@mira@example.org",
                        body: "Does anyone have the new closure notice? The one I quoted last week has gone.",
                        url: "https://example.social/@mira/1",
                        publishedAt: Date(timeIntervalSince1970: 1_800_000_000), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        quote: quote, viewer: Item.Viewer())
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: "m", kind: .mastodonHome, accountID: "a", title: "S", colorIndex: 0)])
        try await store.insert([item])
        return try #require(try await store.rows().first)
    }

    /// The card's padding, one line at the quote's text size and, with an
    /// address, one meta line.
    private func expectedHeight(_ type: Typography, site: Bool) -> CGFloat {
        RowLayout.linkPadding * 2 + Broadsheet.lineHeight(type.quoteUnavailable)
            + (site ? 2 + Broadsheet.lineHeight(type.meta) : 0)
    }

    @Test func itsBoxHasAFixedHeightSetByTheTextSizeAlone() async throws {
        for scale in [CGFloat(1), 1.6] {
            let type = Typography(scale: scale)
            for width in [CGFloat(320), 390, 900] {
                let environment = RowEnvironment(width: width, scale: 3, dark: false, typography: type)
                var heights: Set<CGFloat> = []
                for url in ["https://example.com/a", "https://www.a-very-long-host-name-for-a-quoted-post.example.com/"
                            + String(repeating: "path/", count: 40)] {
                    let geometry = RowLayout.geometry(for: try await row(.unavailable(url: url)), in: environment)
                    let box = try #require(geometry.quote)
                    #expect(geometry.quoteBody == nil && geometry.quoteImage == nil)
                    // One line each: never wrapped, whatever the address.
                    #expect(try #require(geometry.quoteHeader).height == Broadsheet.lineHeight(type.quoteUnavailable))
                    #expect(try #require(geometry.quoteSite).height == Broadsheet.lineHeight(type.meta))
                    #expect(abs(box.height - expectedHeight(type, site: true)) < 0.001)
                    heights.insert(geometry.height)
                }
                #expect(heights.count == 1, "the row's height moved with the address at \(width) × \(scale)")
            }
        }
    }

    @Test func itSitsWhereAQuoteCardGoesAndIsShorterThanOne() async throws {
        let unavailable = RowLayout.geometry(for: try await row(.unavailable(url: "https://example.com/@notices/1")), in: environment)
        let card = RowLayout.geometry(for: try await row(Item.Quote(
            mergeKey: "q", url: "https://example.org/@trust/2001", authorName: "Riverside Trust", authorHandle: "@trust@example.org",
            body: "The boardwalk works finish this week.")), in: environment)
        let box = try #require(unavailable.quote)
        #expect(box.minY == card.quote?.minY && box.width == card.quote?.width)
        #expect(box.minY > unavailable.body.maxY)
        #expect(try #require(unavailable.actions.first).minY > box.maxY)
        #expect(box.height < (card.quote?.height ?? 0))
    }

    @Test func itOpensItsAddressAndVoiceOverReadsIt() async throws {
        let row = try await row(.unavailable(url: "https://www.example.com/@notices/1134028"))
        let geometry = RowLayout.geometry(for: row, in: environment)
        let box = try #require(geometry.quote)
        let hit = RowHit.at(CGPoint(x: box.midX, y: box.midY), in: row, geometry: geometry, typography: environment.typography)
        guard case .link(let url) = hit else {
            Issue.record("the box didn't open its address")
            return
        }
        #expect(url.absoluteString == "https://www.example.com/@notices/1134028")
        #expect(RowText.accessibilityLabel(row).contains("Quoted post unavailable, example.com"))
        #expect(RowHit.accessibilityActions(for: row).contains { $0.name == "Open quoted post's address" })
    }

    @Test func withoutAnAddressItSaysSoAndOpensNothingOfItsOwn() async throws {
        let row = try await row(.unavailable(url: nil))
        let geometry = RowLayout.geometry(for: row, in: environment)
        let box = try #require(geometry.quote)
        #expect(geometry.quoteSite == nil)
        #expect(abs(box.height - expectedHeight(environment.typography, site: false)) < 0.001)
        // A tap there is a tap on the post, which opens the post's own page.
        let hit = RowHit.at(CGPoint(x: box.midX, y: box.midY), in: row, geometry: geometry, typography: environment.typography)
        switch (hit, RowHit.opening(row)) {
        case (.thread(let tapped)?, .thread(let opened)?): #expect(tapped.mergeKey == opened.mergeKey)
        case (.link(let tapped)?, .link(let opened)?): #expect(tapped == opened)
        default: Issue.record("a tap on the box didn't reach the post")
        }
        #expect(RowText.accessibilityLabel(row).contains("Quoted post unavailable."))
        #expect(!RowHit.accessibilityActions(for: row).contains { $0.name.contains("quoted post") })
    }

    /// Drawn off the main thread into the row's bitmap, in each appearance,
    /// with ink inside the box where its line is.
    @Test(arguments: [false, true])
    func itIsDrawnIntoTheRowBitmapOffTheMainThread(dark: Bool) async throws {
        let environment = RowEnvironment(width: 390, scale: 2, dark: dark, typography: Typography(scale: 1))
        let row = try await row(.unavailable(url: "https://example.com/@notices/1134028"))
        let geometry = RowLayout.geometry(for: row, in: environment)
        let image = try #require(await Task.detached {
            RowRenderer.render(row, geometry: geometry, in: environment)?.image
        }.value)
        #expect(image.height == Int((geometry.height * 2).rounded(.up)))
        let line = try #require(geometry.quoteHeader)
        #expect(try inkedPixels(in: line, of: image, scale: 2) > 20)
        Attachment.record(try png(image), named: "unavailable-quote-row-\(dark ? "dark" : "light").png")
    }

    // MARK: - The thread view

    @MainActor
    @Test(arguments: [false, true])
    func theThreadsQuoteCardsAndNotesDraw(dark: Bool) throws {
        let quote = Item.Quote(mergeKey: "q", url: "https://example.org/@trust/2001", authorName: "Riverside Trust",
                               authorHandle: "@trust@example.org", body: "The boardwalk works finish this week.")
        let note = try #require(PostThread(
            ancestors: [], post: Item(sourceID: "s", remoteID: "f", kind: .post, mergeKey: "f", authorName: "A", authorHandle: "@a",
                                      body: "x", url: "https://example.com/posts/f", publishedAt: .now, fetchedAt: .now),
            replies: [], gaps: [.init(position: .ancestors, reason: .deleted), .init(position: .ancestors, reason: .unavailable)]
        ).missingNote(at: .ancestors))
        let pieces: [(String, AnyView)] = [
            ("quote", AnyView(ThreadQuoteCard(quote: quote))),
            ("unavailable", AnyView(ThreadQuoteCard(quote: .unavailable(url: "https://example.net/@notices/1134028")))),
            ("missing", AnyView(ThreadMissingNoteView(note: note, wholeThread: (URL(string: "https://example.com/posts/f")!, "example.com")))),
        ]
        for (name, view) in pieces {
            let image = try #require(snapshot(view, dark: dark))
            #expect(image.width > 0 && image.height > 0)
            Attachment.record(try png(image), named: "thread-\(name)-\(dark ? "dark" : "light").png")
        }
    }

    /// The unavailable card's lines are cut short, so its height doesn't
    /// move with its address.
    @MainActor
    @Test func theThreadsUnavailableCardKeepsOneHeight() throws {
        let short = try #require(snapshot(AnyView(ThreadQuoteCard(quote: .unavailable(url: "https://example.com/1"))), dark: false))
        let long = try #require(snapshot(AnyView(ThreadQuoteCard(quote: .unavailable(
            url: "https://a-very-long-host-name-for-a-quoted-post-that-would-wrap.example.com/" + String(repeating: "x", count: 300)))),
            dark: false))
        #expect(short.height == long.height)
    }

    // MARK: -

    @MainActor
    private func snapshot(_ view: AnyView, dark: Bool) -> CGImage? {
        let renderer = ImageRenderer(content: view
            .frame(width: 360)
            .background(Color.paint(Broadsheet.paper))
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        return renderer.cgImage
    }

    /// How many pixels in `rect` (points) differ clearly from the row's
    /// top-left pixel, its paper.
    private func inkedPixels(in rect: CGRect, of image: CGImage, scale: CGFloat) throws -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        let paper = pixel(1, 1)
        var count = 0
        for y in Int(rect.minY * scale)..<min(Int(rect.maxY * scale), height) {
            for x in Int(rect.minX * scale)..<min(Int(rect.maxX * scale), width) {
                let p = pixel(x, y)
                if abs(p.0 - paper.0) + abs(p.1 - paper.1) + abs(p.2 - paper.2) > 60 { count += 1 }
            }
        }
        return count
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
