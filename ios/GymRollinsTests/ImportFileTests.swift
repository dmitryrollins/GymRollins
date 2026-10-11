import Foundation
import Testing
@testable import GymRollins

/// Security: CSV import refuses files over 25 MB before reading them.
@Suite struct ImportFileTests {
    private func tempFile(bytes: Int? = nil, text: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID()).csv")
        try Data((text ?? "").utf8).write(to: url)
        if let bytes {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(bytes)) // sparse: no real 26 MB write
            try handle.close()
        }
        return url
    }

    @Test func oversizedFileIsRefused() throws {
        let url = try tempFile(bytes: ImportFile.maxBytes + 1)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ImportFile.Failure.tooLarge) { try ImportFile.readText(at: url) }
        #expect(ImportFile.Failure.tooLarge.message.contains("25 MB"))
    }

    @Test func fileAtTheCapAndSmallFilesAreRead() throws {
        let small = try tempFile(text: "Date,Exercise\n")
        defer { try? FileManager.default.removeItem(at: small) }
        #expect(try ImportFile.readText(at: small) == "Date,Exercise\n")
        let atCap = try tempFile(text: "abcd")
        defer { try? FileManager.default.removeItem(at: atCap) }
        #expect(try ImportFile.readText(at: atCap, maxBytes: 4) == "abcd")
        #expect(throws: ImportFile.Failure.tooLarge) { try ImportFile.readText(at: atCap, maxBytes: 3) }
    }

    @Test func missingOrNonUTF8FilesAreUnreadable() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID()).csv")
        #expect(throws: ImportFile.Failure.unreadable) { try ImportFile.readText(at: missing) }
        let binary = FileManager.default.temporaryDirectory.appending(path: "bin-\(UUID()).csv")
        try Data([0xFF, 0xFE, 0xFD]).write(to: binary)
        defer { try? FileManager.default.removeItem(at: binary) }
        #expect(throws: ImportFile.Failure.unreadable) { try ImportFile.readText(at: binary) }
    }
}
