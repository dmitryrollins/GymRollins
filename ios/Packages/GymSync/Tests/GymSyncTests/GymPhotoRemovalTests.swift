import Foundation
import GymData
import Testing
@testable import GymSync

@Suite struct GymPhotoRemovalTests {
    private func photos(_ bucket: String, _ count: Int) -> [OwnedPhoto] {
        (0..<count).map { OwnedPhoto(bucketId: bucket, name: "\(bucket)-\($0).jpg") }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(bucket: String, names: [String])] = []
        func add(_ bucket: String, _ names: [String]) { lock.withLock { all.append((bucket, names)) } }
        var value: [(bucket: String, names: [String])] { lock.withLock { all } }
    }

    @Test func removesEachBucketInBatches() async throws {
        let calls = Calls()
        let rows = photos("gym-photos", 5) + photos("gym-photos-private", 2)
        try await SupabaseGymCatalogTransport.removeAll(rows, batchSize: 2) { calls.add($0, $1) }
        #expect(calls.value.map(\.bucket) == ["gym-photos", "gym-photos", "gym-photos", "gym-photos-private"])
        #expect(calls.value.map(\.names.count) == [2, 2, 1, 2])
    }

    @Test func stopsAtTheFirstFailureAndThrowsIt() async {
        struct Refused: Error, Equatable {}
        let calls = Calls()
        let rows = photos("gym-photos", 6) + photos("gym-photos-private", 1)
        await #expect(throws: Refused.self) {
            try await SupabaseGymCatalogTransport.removeAll(rows, batchSize: 2) { bucket, names in
                calls.add(bucket, names)
                if calls.value.count == 2 { throw Refused() }
            }
        }
        #expect(calls.value.count == 2, "nothing after the failing batch was tried")
    }

    @Test func nothingToRemoveCallsNothing() async throws {
        let calls = Calls()
        try await SupabaseGymCatalogTransport.removeAll([]) { calls.add($0, $1) }
        #expect(calls.value.isEmpty)
    }

    @Test func readsTheServersPhotoList() throws {
        let json = Data(#"[{"bucket_id":"gym-photos","name":"a.jpg"},{"bucket_id":"gym-photos-private","name":"b.jpg"}]"#.utf8)
        #expect(try SupabaseGymCatalogTransport.ownedPhotos(from: json)
            == [OwnedPhoto(bucketId: "gym-photos", name: "a.jpg"), OwnedPhoto(bucketId: "gym-photos-private", name: "b.jpg")])
        #expect(throws: (any Error).self) { try SupabaseGymCatalogTransport.ownedPhotos(from: Data("nope".utf8)) }
    }

    // MARK: removeEverything

    private func photoLists(_ lists: [[OwnedPhoto]]) -> @Sendable () async throws -> [OwnedPhoto] {
        let next = Counter()
        return { lists[min(next.bump(), lists.count - 1)] }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() -> Int { lock.withLock { defer { value += 1 }; return value } }
    }

    @Test func listsAgainAfterEachPassAndStopsWhenNothingIsLeft() async throws {
        let calls = Calls()
        let first = photos("gym-photos", 2), second = photos("gym-photos-private", 1)
        try await SupabaseGymCatalogTransport.removeEverything(list: photoLists([first, second, []])) {
            calls.add($0, $1)
        }
        #expect(calls.value.map(\.names.count) == [2, 1])
    }

    @Test func theSameObjectsAgainMeanStorageIsNotRemovingThem() async {
        let calls = Calls()
        let stuck = photos("gym-photos", 2)
        let thrown = await #expect(throws: GymCatalogError.self) {
            try await SupabaseGymCatalogTransport.removeEverything(list: photoLists([stuck, stuck, stuck])) {
                calls.add($0, $1)
            }
        }
        #expect(thrown == .rejected("photos remain"))
        #expect(calls.value.count == 1, "it asked once more, saw the same objects, and gave up")
    }

    @Test func aUserWhosePhotosKeepAppearingIsStoppedAtThePassLimit() async {
        let calls = Calls()
        let lists = (0..<10).map { pass in [OwnedPhoto(bucketId: "gym-photos", name: "pass-\(pass).jpg")] }
        let thrown = await #expect(throws: GymCatalogError.self) {
            try await SupabaseGymCatalogTransport.removeEverything(maxPasses: 3, list: photoLists(lists)) {
                calls.add($0, $1)
            }
        }
        #expect(thrown == .rejected("photos remain"))
        #expect(calls.value.count == 3, "one removal per pass, and no fourth pass")
    }
}
