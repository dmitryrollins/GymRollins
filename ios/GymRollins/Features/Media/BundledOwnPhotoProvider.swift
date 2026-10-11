import Foundation
import GymCore

/// GymRollins' own exercise photos shipped in the app bundle (Resources/OwnPhotos, copied as the `OwnPhotos` folder),
/// named `own-<exerciseId>-<frame>.jpg` with frame 0 = start position, 1 = end position. They replace the
/// free-exercise-db stopgap one exercise at a time: drop the files in, no mapping to edit.
struct BundledOwnPhotoProvider: ExerciseMediaProvider {
    static let prefix = "own-"
    static let folder = "OwnPhotos"

    private let photos: [String: [URL]]

    /// `files`: candidate bundle resources; anything not matching the naming scheme is ignored.
    init(files: [URL]) {
        var frames: [String: [(frame: Int, url: URL)]] = [:]
        for url in files {
            guard let (id, frame) = Self.parse(url.lastPathComponent) else { continue }
            frames[id, default: []].append((frame, url))
        }
        photos = frames.mapValues { $0.sorted { $0.frame < $1.frame }.map(\.url) }
    }

    static func bundled(_ bundle: Bundle = .main) -> BundledOwnPhotoProvider {
        BundledOwnPhotoProvider(files: bundle.urls(forResourcesWithExtension: "jpg", subdirectory: folder) ?? [])
    }

    func media(for exercise: Exercise) -> ExerciseMedia? {
        photos[exercise.id].map { ExerciseMedia(photos: $0, animation: nil, source: .own) }
    }

    /// `own-0453-1.jpg` -> ("0453", 1).
    static func parse(_ name: String) -> (id: String, frame: Int)? {
        guard name.hasPrefix(prefix), name.hasSuffix(".jpg") else { return nil }
        let parts = name.dropFirst(prefix.count).dropLast(4).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = parts.first, !id.isEmpty, id.allSatisfy(\.isNumber),
              let frame = Int(parts[1]), frame >= 0 else { return nil }
        return (String(id), frame)
    }
}
