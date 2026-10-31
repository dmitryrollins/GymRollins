import Foundation
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct ModerationModelTests {
    private let photo = "33333333-3333-4333-8333-333333333333.jpg"

    private func entry(_ title: String, photo: String? = nil, type: GymTargetType = .listing) -> ModerationEntry {
        ModerationEntry(targetType: type, targetId: UUID(), title: title, photoPath: photo, reportCount: 3,
                        reasons: [.init(reason: "person-in-photo", count: 2), .init(reason: "spam", count: 1)],
                        notes: ["a face"])
    }

    private func rig(_ entries: [ModerationEntry]) -> (ModerationModel, StubCatalogTransport) {
        let stub = StubCatalogTransport()
        stub.queue = entries
        stub.photoOnRemove = photo
        return (ModerationModel(transport: stub), stub)
    }

    @Test func loadingShowsTheQueueWithReasonsByCountAndNotes() async {
        let (model, _) = rig([entry("Acme X1", photo: photo)])
        await model.load()
        let row = model.entries.first
        #expect(row?.title == "Acme X1")
        #expect(row?.reasons.map(\.count) == [2, 1])
        #expect(row?.notes == ["a face"])
        #expect(model.loaded)
        #expect(model.error == nil)
    }

    @Test func reasonsReadAsPlainWordsWithTheirCount() {
        #expect(ModerationModel.reasonLine(.init(reason: "person-in-photo", count: 2)) == "Person in the photo x2")
        #expect(ModerationModel.reasonLine(.init(reason: "spam", count: 1)) == "Spam x1")
        #expect(ModerationModel.reasonLine(.init(reason: "from-a-newer-app", count: 3)) == "from-a-newer-app x3")
    }

    @Test func removeDeletesTheReturnedPhotoThenDropsTheRow() async {
        let target = entry("Acme X1", photo: photo)
        let (model, stub) = rig([target, entry("Other")])
        await model.load()
        await model.remove(target)
        #expect(stub.calls.contains("moderate:remove"))
        #expect(stub.calls.contains("deleteSharedPhoto:\(photo)"))
        let order = stub.calls.filter { $0 == "moderate:remove" || $0.hasPrefix("deleteSharedPhoto") }
        #expect(order == ["moderate:remove", "deleteSharedPhoto:\(photo)"])
        #expect(model.entries.map(\.title) == ["Other"])
        #expect(model.notice == nil)
    }

    @Test func aPhotoThatCouldNotBeDeletedSaysSoAndStillDropsTheRow() async {
        let target = entry("Acme X1", photo: photo)
        let (model, stub) = rig([target])
        stub.deleteFailure = .offline
        await model.load()
        await model.remove(target)
        #expect(model.notice == "Removed, but the photo couldn't be deleted. Try again from Storage.")
        #expect(model.entries.isEmpty)
        #expect(model.error == nil)
    }

    @Test func removingAGymHasNoPhotoToDelete() async {
        let gym = entry("Iron Works", type: .gym)
        let (model, stub) = rig([gym])
        stub.photoOnRemove = nil
        await model.load()
        await model.remove(gym)
        #expect(!stub.calls.contains { $0.hasPrefix("deleteSharedPhoto") })
        #expect(model.entries.isEmpty)
    }

    @Test func restoreDropsTheRowAndDeletesNothing() async {
        let target = entry("Acme X1", photo: photo)
        let (model, stub) = rig([target])
        await model.load()
        await model.restore(target)
        #expect(stub.calls.contains("moderate:restore"))
        #expect(!stub.calls.contains { $0.hasPrefix("deleteSharedPhoto") })
        #expect(model.entries.isEmpty)
    }

    @Test func aFailedModerateKeepsTheRowAndShowsTheError() async {
        let target = entry("Acme X1", photo: photo)
        let (model, stub) = rig([target])
        stub.moderateFailure = .offline
        await model.load()
        await model.remove(target)
        #expect(model.entries.map(\.title) == ["Acme X1"])
        #expect(model.error == "No connection. Try again.")
        #expect(!stub.calls.contains { $0.hasPrefix("deleteSharedPhoto") }, "the photo stays while the listing stays")
        stub.moderateFailure = nil
        await model.restore(target)
        #expect(model.entries.isEmpty)
        #expect(model.error == nil, "a new try clears the old message")
    }

    @Test func aNonAdminIsToldPlainlyNotCrashed() async {
        let (model, stub) = rig([])
        stub.queueFailure = .notAllowed
        await model.load()
        #expect(model.error == "Only moderators can see this list.")
        #expect(model.entries.isEmpty)
    }

    @Test func aRestoreThatCannotComeBackExplainsWhy() async {
        let gym = entry("Iron Works", type: .gym)
        let (model, stub) = rig([gym])
        stub.moderateFailure = .placeTaken
        await model.load()
        await model.restore(gym)
        #expect(model.error == "Someone has added this place again since it was removed, so it can't come back.")
        #expect(model.entries.count == 1)
    }

    @Test func aRowThatWasDecidedElsewhereLeavesAfterTheReload() async {
        let a = entry("A"), b = entry("B")
        let (model, stub) = rig([a, b])
        await model.load()
        stub.queue = [b] // another admin removed A meanwhile
        await model.restore(b)
        #expect(model.entries.isEmpty)
        #expect(stub.calls.filter { $0 == "moderationQueue" }.count == 2, "reloaded rather than assumed")
    }
}
