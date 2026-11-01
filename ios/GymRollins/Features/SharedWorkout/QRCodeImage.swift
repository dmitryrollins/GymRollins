import CoreImage
import CoreImage.CIFilterBuiltins

/// A QR code for a link: correction level M, dark on white with its quiet zone, scaled by a whole number so the edges stay
/// sharp.
enum QRCodeImage {
    private static let quietZoneModules: CGFloat = 4

    static func make(_ text: String, side: CGFloat = 1024) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let canvas = code.extent.insetBy(dx: -quietZoneModules, dy: -quietZoneModules)
        let withQuietZone = code.composited(over: CIImage(color: .white).cropped(to: canvas))
        let scale = (side / canvas.width).rounded(.down)
        guard scale >= 1 else { return nil }
        let scaled = withQuietZone.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
