import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum GymPhotoError: Error, Equatable { case notAnImage, tooBig, faceDetectionFailed }

struct ProcessedGymPhoto: Sendable {
    let jpeg: Data
    let thumbnail: Data
}

protocol FaceDetecting: Sendable {
    /// Face rectangles, normalized, Vision's bottom-left origin.
    func faces(in image: CGImage) throws -> [CGRect]
}

struct VisionFaceDetector: FaceDetecting {
    func faces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map(\.boundingBox)
    }
}

/// Cleans a gym photo before it is saved or shared: downscaled, faces blurred, all metadata gone, plus a thumbnail.
/// It throws rather than ever returning an image whose faces might be showing.
struct GymPhotoProcessor: Sendable {
    static let maxLongEdge = 1600, thumbnailLongEdge = 400, maxBytes = 1_000_000
    static let quality = 0.7, retryQuality = 0.5
    /// Added around each face rect on every side, as a fraction of its size.
    static let facePadding = 0.35

    private let detector: any FaceDetecting
    private let maxBytes: Int

    init(detector: any FaceDetecting = VisionFaceDetector(), maxBytes: Int = Self.maxBytes) {
        self.detector = detector
        self.maxBytes = maxBytes
    }

    func process(_ data: Data) throws -> ProcessedGymPhoto {
        let upright = try Self.decode(data)
        let faces: [CGRect]
        do {
            faces = try detector.faces(in: upright)
        } catch {
            throw GymPhotoError.faceDetectionFailed
        }
        let blurred = try Self.blur(faces: faces, in: upright)
        let jpeg = try encodeWithinLimit(blurred)
        let thumb = Self.resized(blurred, longEdge: Self.thumbnailLongEdge)
        guard let thumbData = Self.jpeg(thumb, quality: Self.quality) else { throw GymPhotoError.notAnImage }
        return ProcessedGymPhoto(jpeg: jpeg, thumbnail: thumbData)
    }

    // MARK: Steps

    /// Upright (EXIF orientation applied) and at most `maxLongEdge` on its long side, never enlarged.
    private static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0
        else { throw GymPhotoError.notAnImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw GymPhotoError.notAnImage }
        return resized(image, longEdge: maxLongEdge)
    }

    /// A strong Gaussian blur over each padded face rect, composited over the original.
    private static func blur(faces: [CGRect], in image: CGImage) throws -> CGImage {
        guard !faces.isEmpty else { return image }
        let original = CIImage(cgImage: image)
        let extent = original.extent
        var result = original
        for face in faces {
            let rect = paddedPixelRect(face, in: extent)
            guard !rect.isEmpty else { continue }
            let radius = max(rect.width, rect.height) / 3
            let blurred = original.clampedToExtent()
                .applyingGaussianBlur(sigma: radius)
                .cropped(to: rect)
            result = blurred.composited(over: result)
        }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = context.createCGImage(result, from: extent) else { throw GymPhotoError.notAnImage }
        return output
    }

    private static func paddedPixelRect(_ face: CGRect, in extent: CGRect) -> CGRect {
        let rect = CGRect(x: face.minX * extent.width, y: face.minY * extent.height,
                          width: face.width * extent.width, height: face.height * extent.height)
        return rect.insetBy(dx: -rect.width * facePadding, dy: -rect.height * facePadding).intersection(extent)
    }

    private func encodeWithinLimit(_ image: CGImage) throws -> Data {
        for quality in [Self.quality, Self.retryQuality] {
            guard let data = Self.jpeg(image, quality: quality) else { throw GymPhotoError.notAnImage }
            if data.count <= maxBytes { return data }
        }
        throw GymPhotoError.tooBig
    }

    // MARK: Pixels

    /// Scales so the long edge is `longEdge`; an image already that small or smaller is returned as an opaque copy.
    private static func resized(_ image: CGImage, longEdge: Int) -> CGImage {
        let long = max(image.width, image.height)
        let scale = long > longEdge ? Double(longEdge) / Double(long) : 1
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Only the quality is passed, so no property of the source (EXIF, GPS, TIFF, orientation) is written.
    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
