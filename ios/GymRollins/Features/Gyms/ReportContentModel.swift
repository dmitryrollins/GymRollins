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

    /// The note as it will be sent: trimmed, cut to the limit, nil when empty.
    static func cleanNote(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(DomainLimits.reportNoteMax))
    }

    /// True when the server's text check would refuse the note: control characters (line breaks are fine),
    /// invisible and text-direction characters. The server stays the judge; this only spares a round trip.
    static func hasRefusedCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0A, 0x0D: false
            case 0x01...0x1F, 0x7F...0x9F, 0x061C, 0x180E, 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x206F,
                 0xFEFF, 0xFFF9...0xFFFB, 0xE0000...0xE007F: true
            default: false
            }
        }
    }
}
