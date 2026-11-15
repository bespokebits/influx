import Foundation
import Testing
@testable import InfluxKit

private func image(_ width: Int, _ height: Int) -> Item.Media {
    Item.Media(kind: .image, url: "https://example.com/\(width)x\(height).jpg", width: width, height: height)!
}

@Suite struct MediaGrids {
    @Test func noMediaHasNoBox() {
        #expect(MediaGrid.frames(for: [], width: 350).isEmpty)
        #expect(MediaGrid.height(for: [], width: 350) == 0)
    }

    @Test func oneImageKeepsItsShape() {
        let frames = MediaGrid.frames(for: [image(1600, 900)], width: 320)
        #expect(frames == [CGRect(x: 0, y: 0, width: 320, height: 180)])
    }

    @Test func aTallImageIsCapped() {
        let frames = MediaGrid.frames(for: [image(1000, 3000)], width: 320)
        #expect(frames == [CGRect(x: 0, y: 0, width: 320, height: 400)])
    }

    @Test func aSmallArticleImageIsNotBlownUp() {
        #expect(MediaGrid.frames(for: [image(151, 151)], width: 320, keepingSmallImagesSmall: true)
                == [CGRect(x: 0, y: 0, width: 151, height: 151)])
        // Large ones still fill the box, and posts' images are left alone.
        #expect(MediaGrid.frames(for: [image(1200, 675)], width: 320, keepingSmallImagesSmall: true)
                == [CGRect(x: 0, y: 0, width: 320, height: 180)])
        #expect(MediaGrid.frames(for: [image(151, 151)], width: 320) == [CGRect(x: 0, y: 0, width: 320, height: 320)])
        // A video's size is its still's, and the player fills the box.
        let video = Item.Media(kind: .video, url: "https://example.com/v.mp4", width: 160, height: 90)!
        #expect(MediaGrid.height(for: [video], width: 320, keepingSmallImagesSmall: true) == 180)
    }

    @Test func aVeryWideImageKeepsAtLeastOnePoint() {
        #expect(MediaGrid.height(for: [image(100_000, 1)], width: 320) == 1)
    }

    @Test func gridsShareOneBoxAndNeverOverlap() {
        for count in 2...6 {
            let media = (0..<count).map { image(1000 + $0, 1000) }
            let frames = MediaGrid.frames(for: media, width: 351)
            #expect(frames.count == min(count, MediaGrid.maxTiles))
            #expect(MediaGrid.height(for: media, width: 351) == (351 / MediaGrid.gridAspect).rounded())
            for frame in frames {
                #expect(frame.minX >= 0 && frame.maxX <= 351 && frame.width > 0 && frame.height > 0)
            }
            for (i, a) in frames.enumerated() {
                for b in frames[(i + 1)...] { #expect(!a.intersects(b)) }
            }
            // The tiles reach both edges of the box.
            #expect(frames.map(\.maxX).max() == 351)
        }
    }

    @Test func threeIsOneLeftAndTwoStackedRight() {
        let frames = MediaGrid.frames(for: [image(1, 1), image(1, 1), image(1, 1)], width: 320)
        #expect(frames[0].height == frames[1].height + frames[2].height + MediaGrid.gap)
        #expect(frames[1].minX == frames[2].minX && frames[1].maxY < frames[2].minY)
    }

    @Test func decodeSizeFillsTheFrameWithoutUpscaling() {
        // A 4000x3000 photo in a 320x180 frame at 3x: width needs 960 px,
        // height needs 540 px of 3000, so fill is 0.24 and the long side 960.
        #expect(MediaGrid.decodeSize(pixelWidth: 4000, pixelHeight: 3000, filling: CGSize(width: 320, height: 180), scale: 3) == 960)
        // Cropped to a square: the short side must cover 480 px.
        #expect(MediaGrid.decodeSize(pixelWidth: 4000, pixelHeight: 2000, filling: CGSize(width: 160, height: 160), scale: 3) == 960)
        // A small image is never scaled up.
        #expect(MediaGrid.decodeSize(pixelWidth: 300, pixelHeight: 200, filling: CGSize(width: 320, height: 213), scale: 3) == 300)
        // Rounded up to a multiple of 64.
        #expect(MediaGrid.decodeSize(pixelWidth: 4000, pixelHeight: 3000, filling: CGSize(width: 100, height: 75), scale: 3) == 320)
    }

    @Test func decodeSizeKeepsExtremeShapesWithinTheBudget() {
        // The reviewer's case: a 1000x100000 strip filling a 320-point-wide
        // tile at 3x would want a 96,000-pixel long side.
        let longest = MediaGrid.decodeSize(pixelWidth: 1000, pixelHeight: 100_000, filling: CGSize(width: 320, height: 400), scale: 3)
        let shortest = Double(longest) * 1000 / 100_000
        #expect(Double(longest) * shortest <= Double(MediaGrid.maxDecodedPixels))
        #expect(longest > 0)
        // The budget alone, for a file whose real shape differs from the
        // stored one.
        let side = MediaGrid.largestDecode(pixelWidth: 1000, pixelHeight: 100_000)
        #expect(Double(side) * Double(side) / 100 <= Double(MediaGrid.maxDecodedPixels))
        #expect(MediaGrid.largestDecode(pixelWidth: 1200, pixelHeight: 900) == 1200)
        // Ordinary photos are untouched by the budget.
        #expect(MediaGrid.decodeSize(pixelWidth: 4000, pixelHeight: 3000, filling: CGSize(width: 430, height: 323), scale: 3) == 1344)
    }
}
