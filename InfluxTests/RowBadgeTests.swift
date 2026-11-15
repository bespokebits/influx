import CoreGraphics
import Foundation
import ImageIO
import Testing
import InfluxKit
@testable import Influx

/// A scored article's row: the badge capsule sits on its own line above
/// the title, VoiceOver reads it, and the glyph in the text stays.
@Suite struct RowBadge {
    private func row(badge: Item.Badge?) async throws -> TimelineRow {
        let store = try InfluxStore.inMemory()
        let source = Source(id: "sammy:s@example.com:feed:f1", kind: .sammyFeed, accountID: "s@example.com", title: "Movies: first scores", colorIndex: 3)
        try await store.save(sources: [source])
        try await store.insert([Item(
            sourceID: source.id, remoteID: "urn:uuid:1", kind: .article, mergeKey: "urn:uuid:1",
            authorName: "Movies: first scores", authorHandle: "example.com", title: "Example Film",
            body: "🟢 74 · Out Oct 24, 2026. Critics call it a patient, beautifully shot ghost story.",
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000), fetchedAt: Date(timeIntervalSince1970: 1_800_000_100),
            badge: badge
        )])
        return try #require(try await store.rows().first)
    }

    @Test func theBadgeSitsAboveTheTitleAndIsSpoken() async throws {
        let environment = RowEnvironment(width: 390, scale: 2, dark: false, typography: Typography(scale: 1))
        let scored = try await row(badge: Item.Badge(text: "74", tone: .favorable))
        let plain = try await row(badge: nil)
        let geometry = RowLayout.geometry(for: scored, in: environment)
        let badge = try #require(geometry.badge)
        let title = try #require(geometry.title)
        #expect(badge.maxY < title.minY)
        #expect(badge.minX == title.minX)
        // The row grows by the badge's line, and nothing else moves.
        let without = RowLayout.geometry(for: plain, in: environment)
        #expect(without.badge == nil)
        #expect(geometry.height > without.height)
        #expect(RowText.accessibilityLabel(scored).contains("Score 74, favorable. Example Film"))
        #expect(RowText.accessibilityLabel(scored).contains("🟢 74"))
        #expect(!RowText.accessibilityLabel(plain).contains("Score"))
    }

    @Test(arguments: [false, true])
    func theRowIsDrawnWithItsBadgeAndGlyph(dark: Bool) async throws {
        let environment = RowEnvironment(width: 390, scale: 2, dark: dark, typography: Typography(scale: 1))
        var images: [CGImage] = []
        for badge in [Item.Badge(text: "74", tone: .favorable), Item.Badge(text: "54", tone: .mixed), Item.Badge(text: "31", tone: .unfavorable)] {
            let scored = try await row(badge: badge)
            let geometry = RowLayout.geometry(for: scored, in: environment)
            let image = try #require(RowRenderer.render(scored, geometry: geometry, in: environment)?.image)
            images.append(image)
        }
        // Kept with the test results as the row's evidence in each
        // appearance.
        Attachment.record(try png(stacking: images), named: "sammy-row-\(dark ? "dark" : "light").png")
    }

    private func png(stacking images: [CGImage]) throws -> Data {
        let width = images.map(\.width).max() ?? 1
        let height = images.map(\.height).reduce(0, +)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var y = height
        for image in images {
            y -= image.height
            context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
