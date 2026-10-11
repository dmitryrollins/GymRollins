import Foundation

/// Reads a CSV the owner picked for import, refusing oversized files before loading them into memory.
enum ImportFile {
    /// Far above any real Fitbod export (years of history is a few MB).
    static let maxBytes = 25 * 1024 * 1024

    enum Failure: Error, Equatable {
        case tooLarge
        case unreadable

        var message: String {
            switch self {
            case .tooLarge: "That file is too large to import (the limit is 25 MB)."
            case .unreadable: "Couldn't read that file."
            }
        }
    }

    static func readText(at url: URL, maxBytes: Int = maxBytes) throws(Failure) -> String {
        let size: Int
        do {
            size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw .unreadable
        }
        guard size <= maxBytes else { throw .tooLarge }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Read at most one byte past the cap: the size can change between the check and the read.
            let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            guard data.count <= maxBytes else { throw Failure.tooLarge }
            guard let text = String(data: data, encoding: .utf8) else { throw Failure.unreadable }
            return text
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .unreadable
        }
    }
}
