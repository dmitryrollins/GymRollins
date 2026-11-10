import Foundation
import ImageIO
import Testing
import UIKit
@testable import GymRollins

/// The camera path: a UIImage is encoded and cleaned together, off the main actor.
@MainActor
@Suite struct GymPhotoCleaningTests {
    private func drawn(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: size.width / 4, y: size.height / 4, width: size.width / 2, height: size.height / 2))
        }
    }

    private func longEdge(of jpeg: Data) throws -> Int {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        return max(width, height)
    }

    @Test func aDrawnCameraImageComesBackAsACleanPhoto() async throws {
        let outcome = await GymPhotoCleaning.clean(drawn(CGSize(width: 3000, height: 2000)))
        guard case let .photo(photo) = outcome else { Issue.record("not cleaned: \(outcome)"); return }
        #expect(photo.jpeg.prefix(2) == Data([0xFF, 0xD8]), "a JPEG")
        #expect(photo.jpeg.count <= GymPhotoProcessor.maxBytes)
        #expect(try longEdge(of: photo.jpeg) == GymPhotoProcessor.maxLongEdge, "shrunk to the size limit")
        #expect(try longEdge(of: photo.thumbnail) == GymPhotoProcessor.thumbnailLongEdge)
    }

    @Test func aSmallCameraImageIsNeverEnlarged() async throws {
        let outcome = await GymPhotoCleaning.clean(drawn(CGSize(width: 600, height: 400)))
        guard case let .photo(photo) = outcome else { Issue.record("not cleaned: \(outcome)"); return }
        #expect(try longEdge(of: photo.jpeg) == 600)
    }

    @Test func anImageThatCannotBeEncodedFails() async {
        let outcome = await GymPhotoCleaning.clean(UIImage())
        guard case let .failed(message) = outcome else { Issue.record("an empty image was accepted"); return }
        #expect(message == GymPhotoError.notAnImage.userMessage)
    }
}
