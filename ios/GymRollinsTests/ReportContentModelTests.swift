import Foundation
import GymData
import Testing
@testable import GymRollins

/// What the report sheet offers and how it treats the note.
@Suite struct ReportContentModelTests {
    @Test func aListingShowsEveryReasonInTheAgreedOrder() {
        #expect(ReportContentModel.reasons(for: .listing).map(ReportContentModel.title) == [
            "Wrong information", "Not here anymore", "Duplicate", "Inappropriate photo", "Person in the photo", "Spam",
            "Something else",
        ])
        #expect(ReportContentModel.reasons(for: .listing).map(\.rawValue) == [
            "wrong-info", "not-here-anymore", "duplicate", "inappropriate-photo", "person-in-photo", "spam", "other",
        ])
    }

    @Test func aPhotoLeadsWithItsTwoReasonsAndAGymHasNoPhotoReasons() {
        #expect(ReportContentModel.reasons(for: .photo).prefix(2) == [.inappropriatePhoto, .personInPhoto])
        #expect(Set(ReportContentModel.reasons(for: .photo)) == Set(ReportReason.allCases))
        #expect(ReportContentModel.reasons(for: .gym) == [.wrongInfo, .notHereAnymore, .duplicate, .spam, .other])
    }

    @Test func theNoteIsTrimmedCutToTheLimitAndEmptyMeansNone() {
        #expect(ReportContentModel.cleanNote("  \n ") == nil)
        #expect(ReportContentModel.cleanNote("  wrong brand ") == "wrong brand")
        #expect(ReportContentModel.cleanNote(String(repeating: "a", count: 400))?.count == 280)
    }

    @Test func charactersTheServerRefusesAreCaughtFirst() {
        #expect(!ReportContentModel.hasRefusedCharacters("Line one\nline two \u{1F3CB} caf\u{E9}"))
        for bad in ["a\u{7}b", "a\u{200B}b", "a\u{202E}b", "a\u{FEFF}b", "a\u{E0041}b", "a\u{85}b"] {
            #expect(ReportContentModel.hasRefusedCharacters(bad), "\(bad.unicodeScalars.map(\.value))")
        }
    }

    @Test func itsMessagesArePlain() {
        #expect(ReportContentModel.thanks == "Thanks. We'll take a look.")
        #expect(ReportContentModel.noteProblem == "The note has characters we can't send. Remove them, or send without a note.")
    }
}
