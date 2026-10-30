import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import GymRollins

private struct StubDetector: FaceDetecting {
    let result: Result<[CGRect], any Error>
    func faces(in image: CGImage) throws -> [CGRect] { try result.get() }
}

private struct DetectorBoom: Error {}

@Suite struct GymPhotoProcessorTests {
    private static func bitmap(_ width: Int, _ height: Int, fill: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        fill(ctx)
        return ctx.makeImage()!
    }

    private static func solid(_ width: Int, _ height: Int) -> CGImage {
        bitmap(width, height) { ctx in
            ctx.setFillColor(UIColor.orange.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private static func noise(_ width: Int, _ height: Int) -> CGImage {
        bitmap(width, height) { ctx in
            let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
            var generator = SystemRandomNumberGenerator()
            for index in 0..<(ctx.bytesPerRow * height) { pixels[index] = UInt8.random(in: 0...255, using: &generator) }
        }
    }

    private static func checkerboard(_ side: Int, cell: Int = 4) -> CGImage {
        bitmap(side, side) { ctx in
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.setFillColor(UIColor.black.cgColor)
            for row in 0..<(side / cell) {
                for col in 0..<(side / cell) where (row + col) % 2 == 0 {
                    ctx.fill(CGRect(x: col * cell, y: row * cell, width: cell, height: cell))
                }
            }
        }
    }

    private static func encode(_ image: CGImage, quality: Double = 0.95, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        options.merge(properties) { _, new in new }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private static func size(of data: Data) -> (Int, Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    /// Mean absolute difference between neighbouring pixels in a region: high for a checkerboard, near 0 once blurred.
    private static func contrast(_ data: Data, in rect: CGRect) -> Double {
        let image = UIImage(data: data)!.cgImage!
        let region = image.cropping(to: rect)!
        let ctx = CGContext(data: nil, width: region.width, height: region.height, bitsPerComponent: 8,
                            bytesPerRow: region.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        var count = 0
        for y in 0..<region.height {
            for x in 0..<(region.width - 1) {
                let a = Int(px[(y * region.width + x) * 4]), b = Int(px[(y * region.width + x + 1) * 4])
                total += Double(abs(a - b))
                count += 1
            }
        }
        return total / Double(count)
    }

    private func processor(faces: [CGRect] = [], maxBytes: Int = GymPhotoProcessor.maxBytes) -> GymPhotoProcessor {
        GymPhotoProcessor(detector: StubDetector(result: .success(faces)), maxBytes: maxBytes)
    }

    @Test func downscalesToTheLongEdge() throws {
        let out = try processor().process(Self.encode(Self.solid(4000, 3000)))
        let (w, h) = Self.size(of: out.jpeg)
        #expect(max(w, h) == 1600)
        #expect(w == 1600 && h == 1200)
        let (tw, th) = Self.size(of: out.thumbnail)
        #expect(max(tw, th) == 400)

        let small = try processor().process(Self.encode(Self.solid(300, 200)))
        let (sw, sh) = Self.size(of: small.jpeg)
        #expect(sw == 300 && sh == 200, "never upscaled")
        let (stw, sth) = Self.size(of: small.thumbnail)
        #expect(stw == 300 && sth == 200, "thumbnail never upscaled")
    }

    @Test func staysUnderOneMegabyte() {
        let input = Self.encode(Self.noise(4000, 3000), quality: 1.0)
        do {
            let out = try processor().process(input)
            #expect(out.jpeg.count <= 1_000_000)
        } catch {
            #expect(error as? GymPhotoError == .tooBig)
        }
    }

    @Test func rejectsWhatStaysTooBig() {
        #expect(throws: GymPhotoError.tooBig) {
            try processor(maxBytes: 1_000).process(Self.encode(Self.noise(800, 600)))
        }
    }

    @Test func stripsAllMetadata() throws {
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret-comment"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.5, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 13.4, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: "Cam"]
        ]
        let input = Self.encode(Self.solid(800, 600), properties: props)
        let inSource = CGImageSourceCreateWithData(input as CFData, nil)!
        let inProps = CGImageSourceCopyPropertiesAtIndex(inSource, 0, nil) as? [CFString: Any] ?? [:]
        #expect(inProps[kCGImagePropertyGPSDictionary] != nil, "fixture really carries GPS")

        let out = try processor().process(input)
        for data in [out.jpeg, out.thumbnail] {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let outProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            #expect(outProps[kCGImagePropertyGPSDictionary] == nil)
            #expect(outProps[kCGImagePropertyTIFFDictionary] == nil)
            let exif = outProps[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(exif?[kCGImagePropertyExifUserComment] == nil)
            #expect(!data.contains(Data("secret-comment".utf8)))
            #expect(!data.contains(Data("Acme".utf8)))
        }
    }

    @Test func respectsOrientation() throws {
        let landscape = Self.solid(600, 400)
        let input = Self.encode(landscape, properties: [kCGImagePropertyOrientation: 6])
        let (w, h) = Self.size(of: try processor().process(input).jpeg)
        #expect(w == 400 && h == 600)
    }

    @Test func blursEachFaceRegion() throws {
        let input = Self.encode(Self.checkerboard(800), quality: 1.0)
        // Normalized, bottom-left origin: a 0.2 square centred low-left. Padded by 0.35 on every side.
        let face = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let out = try processor(faces: [face]).process(input)
        // Image row 0 is the top, so a face at y 0.2...0.4 from the bottom sits at rows 480...640 of 800.
        let inside = CGRect(x: 180, y: 500, width: 100, height: 100)
        let outside = CGRect(x: 600, y: 50, width: 100, height: 100)
        #expect(Self.contrast(out.jpeg, in: inside) < 20)
        #expect(Self.contrast(out.jpeg, in: outside) > 50)
        #expect(Self.contrast(out.thumbnail, in: CGRect(x: 90, y: 250, width: 50, height: 50)) < 20,
                "the thumbnail is cut from the blurred image")
    }

    @Test func detectorFailureRejectsThePhoto() {
        let failing = GymPhotoProcessor(detector: StubDetector(result: .failure(DetectorBoom())))
        #expect(throws: GymPhotoError.faceDetectionFailed) { try failing.process(Self.encode(Self.solid(400, 300))) }
    }

    @Test func notAnImageThrows() {
        #expect(throws: GymPhotoError.notAnImage) { try processor().process(Data((0..<500).map { _ in UInt8.random(in: 0...255) })) }
        #expect(throws: GymPhotoError.notAnImage) { try processor().process(Data()) }
    }

    private static func fixturePhoto() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "own-0453-0", withExtension: "jpg", subdirectory: "OwnPhotos"))
        return try Data(contentsOf: url)
    }

    @Test func findsTheFaceInTheFixture() throws {
        let image = try #require(UIImage(data: try Self.fixturePhoto())?.cgImage)
        let faces = try VisionFaceDetector().faces(in: image)
        #expect(faces.count == 1)
        let face = try #require(faces.first)
        #expect(abs(face.midX - 0.51) < 0.05 && abs(face.midY - 0.77) < 0.05, "at \(face)")
    }

    @Test func blursTheRealFaceAndLeavesTheRest() throws {
        let input = try Self.fixturePhoto()
        let out = try GymPhotoProcessor().process(input)
        let untouched = try processor().process(input)
        let image = try #require(UIImage(data: out.jpeg))
        // The face, in image coordinates (row 0 is the top), from `findsTheFaceInTheFixture`'s position.
        let original = try #require(UIImage(data: input)?.cgImage)
        let face = try #require(try VisionFaceDetector().faces(in: original).first)
        let inside = CGRect(x: face.minX * image.size.width, y: (1 - face.maxY) * image.size.height,
                            width: face.width * image.size.width, height: face.height * image.size.height)
        #expect(Self.contrast(out.jpeg, in: inside) * 3 < Self.contrast(untouched.jpeg, in: inside),
                "the face has lost most of its detail")
        let elsewhere = CGRect(x: 0, y: image.size.height * 0.5, width: image.size.width * 0.3, height: image.size.height * 0.3)
        #expect(abs(Self.contrast(out.jpeg, in: elsewhere) - Self.contrast(untouched.jpeg, in: elsewhere)) < 1)
        let cleaned = try #require(image.cgImage)
        #expect(try VisionFaceDetector().faces(in: cleaned).isEmpty, "no face is detectable afterwards")
    }
}

private extension Data {
    func contains(_ other: Data) -> Bool { range(of: other) != nil }
}
