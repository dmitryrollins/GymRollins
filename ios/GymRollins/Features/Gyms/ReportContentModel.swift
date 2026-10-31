import Foundation
import GymCore
import GymData

/// What the report sheet offers and checks, as plain data so the rules are tested without a screen.
enum ReportContentModel {
    /// What is being reported: it decides which reasons make sense.
    enum Subject: Equatable { case listing, gym, photo }

    static let thanks = "Thanks. We'll take a look."
    static let noteProblem = "The note has characters we can't send. Remove them, or send without a note."

    static func title(_ reason: ReportReason) -> String {
        switch reason {
        case .wrongInfo: "Wrong information"
        case .notHereAnymore: "Not here anymore"
        case .duplicate: "Duplicate"
        case .inappropriatePhoto: "Inappropriate photo"
        case .personInPhoto: "Person in the photo"
        case .spam: "Spam"
        case .other: "Something else"
        }
    }

    private static let photoReasons: [ReportReason] = [.inappropriatePhoto, .personInPhoto]

    /// A photo's report leads with the two photo reasons; a gym has no photo to report.
    static func reasons(for subject: Subject) -> [ReportReason] {
        let all = ReportReason.allCases
        switch subject {
        case .listing: return all
        case .gym: return all.filter { !photoReasons.contains($0) }
        case .photo: return photoReasons + all.filter { !photoReasons.contains($0) }
        }
    }

    /// The note as it will be sent: trimmed, cut to the limit, nil when empty. The server counts code points
    /// (`char_length`), so the limit does too.
    static func cleanNote(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : cut(trimmed)
    }

    static func cut(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > DomainLimits.reportNoteMax else { return text }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars.prefix(DomainLimits.reportNoteMax))
        return String(kept)
    }

    // The server's `gym_private.clean_text(note, true)`. Controls except line breaks, the C1 controls and every invisible
    // or formatting character it lists.
    private static let hiddenRanges: [ClosedRange<UInt32>] = [
        0x7F...0x9F, 0xAD...0xAD, 0x34F...0x34F, 0x61C...0x61C, 0x115F...0x1160, 0x17B4...0x17B5, 0x180B...0x180F,
        0x200B...0x200B, 0x200E...0x200F, 0x2028...0x202E, 0x2060...0x206F, 0x3164...0x3164, 0xFE00...0xFE0E,
        0xFEFF...0xFEFF, 0xFFA0...0xFFA0, 0xFFF9...0xFFFC, 0xE000...0xF8FF, 0x1D173...0x1D17A, 0xE0000...0xE01EF,
        0xF0000...0xFFFFD, 0x100000...0x10FFFD,
    ]
    private static let joiners: Set<UInt32> = [0x200C, 0x200D]
    private static let emojiSelector: UInt32 = 0xFE0F

    /// True when the server's text check would refuse the note: control characters (line breaks are fine), invisible
    /// and text-direction characters, and a joiner or emoji selector that doesn't sit next to non-ASCII text (between
    /// ASCII letters it can only hide something). The server stays the judge; this only spares a round trip.
    static func hasRefusedCharacters(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars.map(\.value))
        for (index, value) in scalars.enumerated() {
            if isRefused(value) { return true }
            let previousIsText = index > 0 && scalars[index - 1] > 0x7F
            let nextIsText = index + 1 < scalars.count && scalars[index + 1] > 0x7F
            if joiners.contains(value), !previousIsText || !nextIsText { return true }
            if value == emojiSelector, !previousIsText { return true }
        }
        return false
    }

    private static func isRefused(_ value: UInt32) -> Bool {
        switch value {
        case 0x0A, 0x0D: false
        case 0x00...0x1F: true
        default: hiddenRanges.contains { $0.contains(value) }
        }
    }
}
