import Foundation

enum GymPhotoStoreError: Error, Equatable {
    case invalidFileName
}

/// Keeps cleaned gym photos (and their thumbnails) in Application Support, which the OS never purges. Listings
/// remember only the file name, so every name is checked before it becomes a path.
struct GymPhotoStore: Sendable {
    private let directory: URL

    init(directory: URL = Self.standardDirectory) { self.directory = directory }

    static var standardDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GymPhotos", isDirectory: true)
    }

    /// Writes both files and returns the photo's file name (`<uuid>.jpg`).
    func save(_ photo: ProcessedGymPhoto) throws -> String {
        let name = "\(UUID().uuidString).jpg"
        try save(photo, as: name)
        return name
    }

    /// Writes both files under a given name (a downloaded picture keeps the name sync chose).
    func save(_ photo: ProcessedGymPhoto, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try photo.jpeg.write(to: url(name), options: .atomic)
        do {
            try photo.thumbnail.write(to: thumbnailURL(name), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: url(name))
            throw error
        }
    }

    func url(_ fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    func thumbnailURL(_ fileName: String) -> URL {
        directory.appendingPathComponent(fileName.replacingOccurrences(of: ".jpg", with: "-thumb.jpg"))
    }

    /// Removes both files. A file that is already gone is fine.
    func delete(_ fileName: String) throws {
        guard Self.isSafe(fileName) else { throw GymPhotoStoreError.invalidFileName }
        for target in [url(fileName), thumbnailURL(fileName)] {
            do {
                try FileManager.default.removeItem(at: target)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                continue
            }
        }
    }

    func removeAll() throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }

    static func isSafeName(_ fileName: String) -> Bool { isSafe(fileName) }

    private static func isSafe(_ fileName: String) -> Bool {
        // Only names `save` produces: a bare "." would address the photo folder itself.
        fileName.hasSuffix(".jpg") && !fileName.contains("/") && !fileName.contains("..") && !fileName.contains("\0")
    }
}
