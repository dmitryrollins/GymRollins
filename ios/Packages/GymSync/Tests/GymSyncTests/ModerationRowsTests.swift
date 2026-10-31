import Foundation
import GymData
import Supabase
import Testing
@testable import GymSync

struct ModerationRowsTests {
    private let listing = "11111111-1111-4111-8111-111111111111"
    private let gym = "22222222-2222-4222-8222-222222222222"
    private let photo = "33333333-3333-4333-8333-333333333333.jpg"

    private func entries(_ json: String) throws -> GymCatalogRows.Decoded<ModerationEntry> {
        try GymCatalogRows.moderation(from: Data(json.utf8))
    }

    @Test func aQueueRowKeepsItsCountReasonsAndNotes() throws {
        let json = """
        [{"target_type":"listing","target_id":"\(listing)","title":"Acme X1","photo_path":"\(photo)","report_count":3,
          "reasons":{"spam":1,"person-in-photo":2},"notes":["a face","wrong gym"]},
         {"target_type":"gym","target_id":"\(gym)","title":"Iron Works","photo_path":null,"report_count":0,
          "reasons":{},"notes":[]}]
        """
        let found = try entries(json)
        #expect(found.skipped == 0)
        let first = try #require(found.rows.first)
        #expect(first.targetType == .listing)
        #expect(first.targetId == UUID(uuidString: listing))
        #expect(first.photoPath == photo)
        #expect(first.reportCount == 3)
        #expect(first.reasons.map(\.reason) == ["person-in-photo", "spam"], "most given first")
        #expect(first.reasons.map(\.count) == [2, 1])
        #expect(first.notes == ["a face", "wrong gym"])
        #expect(found.rows.last?.targetType == .gym)
        #expect(found.rows.last?.reasons.isEmpty == true)
    }

    @Test func aPhotoNameThatIsNotAUuidJpgIsDropped() throws {
        let json = """
        [{"target_type":"listing","target_id":"\(listing)","title":"X","photo_path":"../x.jpg","report_count":1,
          "reasons":{},"notes":[]}]
        """
        #expect(try entries(json).rows.first?.photoPath == nil)
    }

    @Test func aRowOfAKindThisVersionDoesNotKnowIsSkippedNotFatal() throws {
        let json = """
        [{"target_type":"item","target_id":"\(listing)","title":"X","photo_path":null,"report_count":1,
          "reasons":{},"notes":[]},
         {"target_type":"gym","target_id":"\(gym)","title":"Y","photo_path":null,"report_count":1,"reasons":{},"notes":[]}]
        """
        let found = try entries(json)
        #expect(found.skipped == 1)
        #expect(found.rows.map(\.title) == ["Y"])
    }

    @Test func theAnswerToModerateGivesTheLowercasePhotoToDelete() throws {
        #expect(try GymCatalogRows.moderatedPhoto(from: Data(#"{"status":"removed","photo_path":"\#(photo)"}"#.utf8)) == photo)
        #expect(try GymCatalogRows.moderatedPhoto(from: Data(#"{"status":"active","photo_path":null}"#.utf8)) == nil)
        #expect(throws: GymCatalogError.self) { try GymCatalogRows.moderatedPhoto(from: Data("[]".utf8)) }
    }

    @Test func theServersRefusalsReadAsPlainCases() {
        let notAdmin = PostgrestError(detail: nil, hint: nil, code: "42501", message: "not allowed")
        #expect(GymCatalogErrors.map(notAdmin, hasSession: true) == .notAllowed)
        #expect(GymCatalogErrors.map(notAdmin, hasSession: false) == .signedOut)
        let taken = PostgrestError(detail: nil, hint: nil, code: "P0001", message: "place_taken")
        #expect(GymCatalogErrors.map(taken, hasSession: true) == .placeTaken)
    }
}
