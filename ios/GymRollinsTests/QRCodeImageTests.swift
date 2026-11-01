import CoreGraphics
import Testing
import Vision
@testable import GymRollins

/// A code that can't be read is no use, so these read it back with Vision.
@Suite struct QRCodeImageTests {
    private func read(_ image: CGImage) throws -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        #if targetEnvironment(simulator)
        // The simulator can't run Vision's newer machine-learning detectors. On its GPU they fail with "Could not create
        // inference context", and on its CPU revisions 3 and 4 find nothing, though they read this same image on a Mac.
        // Revision 2 is the classic detector, and on the CPU it reads the code.
        request.revision = VNDetectBarcodesRequestRevision2
        let cpu = try request.supportedComputeStageDevices[.main]?.first { if case .cpu = $0 { true } else { false } }
        if let cpu { try request.setComputeDevice(cpu, for: .main) }
        #endif
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.first?.payloadStringValue
    }

    @Test func aShortLinkReadsBack() throws {
        let link = "gymrollins://w#1.0025_3_8-10"
        #expect(try read(try #require(QRCodeImage.make(link))) == link)
    }

    /// The longest workout a link can hold: 20 exercises with the longest id and every optional field.
    @Test func theLongestLinkReadsBack() throws {
        let fields = (1...20).map { "ABCDEFGH_10_99-100_g\($0)" }.joined(separator: ".")
        let link = "https://a-long-domain-name.example/w#1.\(fields)"
        #expect(try read(try #require(QRCodeImage.make(link))) == link)
    }
}
