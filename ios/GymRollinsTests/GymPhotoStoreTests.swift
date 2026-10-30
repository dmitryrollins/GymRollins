import Foundation
import Testing
@testable import GymRollins

@Suite struct GymPhotoStoreTests {
    private func makeStore() -> (GymPhotoStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gym-photos-\(UUID().uuidString)")
        return (GymPhotoStore(directory: dir), dir)
    }

    private let photo = ProcessedGymPhoto(jpeg: Data("full".utf8), thumbnail: Data("thumb".utf8))

    @Test func savesAndReadsBack() throws {
        let (store, _) = makeStore()
        let name = try store.save(photo)
        #expect(name.hasSuffix(".jpg"))
        #expect(try Data(contentsOf: store.url(name)) == photo.jpeg)
        #expect(try Data(contentsOf: store.thumbnailURL(name)) == photo.thumbnail)
        #expect(FileManager.default.fileExists(atPath: store.thumbnailURL(name).path()))
    }

    @Test func deleteRemovesBothFiles() throws {
        let (store, _) = makeStore()
        let name = try store.save(photo)
        try store.delete(name)
        #expect(!FileManager.default.fileExists(atPath: store.url(name).path()))
        #expect(!FileManager.default.fileExists(atPath: store.thumbnailURL(name).path()))
    }

    @Test func deletingAMissingFileIsNotAnError() throws {
        let (store, _) = makeStore()
        try store.delete("\(UUID().uuidString).jpg")
    }

    @Test func removeAllEmptiesTheFolder() throws {
        let (store, dir) = makeStore()
        _ = try store.save(photo)
        _ = try store.save(photo)
        try store.removeAll()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []
        #expect(left.isEmpty)
        try store.removeAll() // nothing there is fine
    }

    @Test func unsafeFileNamesAreRefused() throws {
        let (store, _) = makeStore()
        for bad in ["../x.jpg", "a/b.jpg", "..", ".", "a..b.jpg", "", "notes.txt"] {
            #expect(throws: GymPhotoStoreError.invalidFileName) { try store.delete(bad) }
        }
    }
}
