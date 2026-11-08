import Foundation
import GymCore
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

    @Test func theLimitCountsCodePointsAsTheServerDoes() {
        // A family emoji is one character to the eye and seven code points to `char_length`.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let cut = ReportContentModel.cleanNote(String(repeating: family, count: 100)) ?? ""
        #expect(cut.unicodeScalars.count == DomainLimits.reportNoteMax)
        #expect(ReportContentModel.cleanNote(String(repeating: "\u{1F3CB}", count: 280))?.unicodeScalars.count == 280)
        #expect(ReportContentModel.cleanNote(String(repeating: "\u{1F3CB}", count: 281))?.unicodeScalars.count == 280)
    }

    /// The cases `server/test/text.test.ts` runs on the server's port of `clean_text`.
    @Test func hiddenCharactersAreRefusedAtBothEndsOfEachRange() {
        func put(_ value: UInt32) -> String { "Iron" + String(UnicodeScalar(value)!) + "Gym" }
        let refused: [UInt32] = [0xAD, 0x34F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B, 0x180C, 0x180D, 0x180E, 0x180F,
                                 0x2028, 0x2029, 0x3164, 0xFE00, 0xFE0A, 0xFE0E, 0xFFA0, 0xFFFC, 0xE000, 0xF8FF, 0xF0000,
                                 0xFFFFD, 0x100000, 0x10FFFD, 0x1D173, 0x1D17A, 0xE0080, 0xE01EF, 0xE0041, 0x61C, 0xFFF9]
        let allowed: [UInt32] = [0xAC, 0xAE, 0x34E, 0x350, 0x115E, 0x1161, 0x17B3, 0x17B6, 0x180A, 0x1810, 0x2027, 0x202F,
                                 0x3163, 0x3165, 0xFDFF, 0xFE10, 0xFF9F, 0xFFA1, 0xFFFD, 0xD7FF, 0xF900, 0xEFFFF,
                                 0xFFFFE, 0x1D172, 0x1D17B, 0xE01F0, 0x1F4AA]
        for value in refused {
            #expect(ReportContentModel.hasRefusedCharacters(put(value)), "U+\(String(value, radix: 16)) is refused")
        }
        for value in allowed {
            #expect(!ReportContentModel.hasRefusedCharacters(put(value)), "U+\(String(value, radix: 16)) passes")
        }
    }

    @Test func joinersAndSelectorsPassOnlyNextToNonASCIIText() {
        let zwj = "\u{200D}", zwnj = "\u{200C}", selector = "\u{FE0F}"
        #expect(ReportContentModel.hasRefusedCharacters("Iron" + zwj + "Gym"), "between ASCII letters")
        #expect(ReportContentModel.hasRefusedCharacters(zwj + "Iron"), "at the start")
        #expect(ReportContentModel.hasRefusedCharacters("Iron" + zwnj + "Gym"))
        #expect(!ReportContentModel.hasRefusedCharacters("\u{1F468}" + zwj + "\u{1F469}"), "an emoji sequence")
        #expect(!ReportContentModel.hasRefusedCharacters("\u{645}" + zwnj + "\u{6CC}"), "a Persian word")
        #expect(!ReportContentModel.hasRefusedCharacters("Iron Gym \u{1F4AA} \u{915}" + zwj + "\u{937}"), "a script that needs it")
        #expect(!ReportContentModel.hasRefusedCharacters("Heart \u{2764}" + selector), "a selector after non-ASCII")
        #expect(ReportContentModel.hasRefusedCharacters("Iron" + selector + "Gym"), "but not between ASCII letters")
        #expect(ReportContentModel.hasRefusedCharacters(selector + "Iron"), "nor at the start")
        #expect(ReportContentModel.hasRefusedCharacters("Iron " + selector), "nor after ASCII at the end")
        #expect(ReportContentModel.hasRefusedCharacters("a\u{1F468}" + zwj), "a joiner at the end")
        #expect(ReportContentModel.hasRefusedCharacters("\u{1F468}" + zwj + "a"), "or before ASCII")
    }

    @Test func controlsAreRefusedExceptLineBreaks() {
        #expect(!ReportContentModel.hasRefusedCharacters("two\nlines"))
        #expect(!ReportContentModel.hasRefusedCharacters("two\r\nlines"))
        for bad in ["a\u{1}b", "a\u{9}b", "a\u{B}b", "a\u{C}b", "a\u{E}b", "a\u{1F}b", "a\u{7F}b", "a\u{9F}b", "a\u{0}b"] {
            #expect(ReportContentModel.hasRefusedCharacters(bad), "\(bad.unicodeScalars.map(\.value))")
        }
        #expect(ReportContentModel.hasRefusedCharacters("two\nlines\u{2028}"), "the line separator, even where lines are allowed")
        #expect(!ReportContentModel.hasRefusedCharacters("\u{C9}quinoxe Fitness \u{2013} 24/7 (N\u{F8}rre) \u{5065}\u{8EAB}\u{623F}"))
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
