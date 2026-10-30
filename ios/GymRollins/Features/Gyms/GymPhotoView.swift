import ImageIO
import SwiftUI
import UIKit

/// A cleaned gym photo (or its thumbnail) from `env.gymPhotos`, read and shrunk to its display size off the main
/// thread. A placeholder shows while it loads, with no file name, and when the file can't be read.
struct GymPhotoView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.displayScale) private var scale
    let fileName: String?
    var width: CGFloat = 52
    var height: CGFloat?
    /// The full photo instead of the 400 px thumbnail.
    var full = false
    var cornerRadius: CGFloat = 12
    var placeholderSymbol = "photo"
    @State private var image: UIImage?

    private var displayHeight: CGFloat { height ?? width }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Theme.cardInner
                Image(systemName: placeholderSymbol).font(.title3).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: width, height: displayHeight)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: fileName) { await load() }
    }

    private func load() async {
        guard let fileName else { image = nil; return }
        let url = full ? env.gymPhotos.url(fileName) : env.gymPhotos.thumbnailURL(fileName)
        let maxPixels = max(width, displayHeight) * scale
        let loaded = await Task.detached(priority: .userInitiated) { Self.downsample(url, maxPixels: maxPixels) }.value
        guard !Task.isCancelled else { return }
        image = loaded
    }

    /// Decodes at most `maxPixels` on the long edge, so a 1600 px photo never sits in memory at full size.
    nonisolated private static func downsample(_ url: URL, maxPixels: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
