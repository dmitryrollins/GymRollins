import Foundation
import GymData
import Observation

/// The admin list: what is flagged, and Restore or Remove for each. A removal also deletes the listing's photo through
/// Storage, which SQL can't do, and then tells the server it is gone. Until then the row stays, so a failed delete can
/// be tried again.
@MainActor
@Observable
final class ModerationModel {
    static let photoNotice = "Removed, but the photo couldn't be deleted. Tap Remove to try again."
    static let photoPending = "Photo still to delete"

    private(set) var entries: [ModerationEntry] = []
    private(set) var loaded = false
    private(set) var error: String?
    /// Shown beside the list when a removal went through but its photo did not; the row stays so Remove can try again.
    private(set) var notice: String?
    private(set) var busy: Set<UUID> = []
    private let transport: any GymCatalogTransport

    init(transport: any GymCatalogTransport) { self.transport = transport }

    static func reasonLine(_ item: ModerationEntry.ReasonCount) -> String {
        let name = ReportReason(rawValue: item.reason).map(ReportContentModel.title) ?? item.reason
        return "\(name) x\(item.count)"
    }

    /// The status line of a row: whether the listing is hidden from everyone, and how many reports it has.
    static func statusLine(_ entry: ModerationEntry) -> String {
        let reports = entry.reportCount == 1 ? "1 report" : "\(entry.reportCount) reports"
        switch entry.status {
        case .removed: return photoPending
        case .flagged: return "Hidden, \(reports)"
        case .active: return reports
        }
    }

    func load() async {
        do {
            entries = try await transport.moderationQueue()
            error = nil
        } catch {
            self.error = Self.message(for: error, listing: true)
            AppEnvironment.log.error("Moderation list failed: \(error.localizedDescription, privacy: .public)")
        }
        loaded = true
    }

    func restore(_ entry: ModerationEntry) async { await decide(entry, .restore) }

    func remove(_ entry: ModerationEntry) async { await decide(entry, .remove) }

    private func decide(_ entry: ModerationEntry, _ action: ModerationAction) async {
        guard busy.insert(entry.id).inserted else { return }
        defer { busy.remove(entry.id) }
        error = nil
        notice = nil
        let photo: String?
        do {
            photo = try await transport.moderate(targetType: entry.targetType, targetId: entry.targetId, action: action)
        } catch {
            self.error = Self.message(for: error, listing: false)
            AppEnvironment.log.error("Moderation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // The server keeps the photo's name until it hears the object is gone, so the row stays until then.
        if let photo, !(await delete(photo)) {
            await reload()
            return
        }
        entries.removeAll { $0.id == entry.id }
        await reload()
    }

    /// Deletes the object through Storage, then tells the server. False (with the notice) when either step failed.
    private func delete(_ photo: String) async -> Bool {
        do {
            try await transport.deleteSharedPhoto(path: photo)
            try await transport.moderationPhotoDeleted(path: photo)
            return true
        } catch {
            notice = Self.photoNotice
            AppEnvironment.log.error("Deleting a removed photo failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// What the server says is left, since another admin may have decided rows too. A failure keeps what is shown.
    private func reload() async {
        do {
            entries = try await transport.moderationQueue()
        } catch {
            AppEnvironment.log.error("Moderation reload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func message(for error: Error, listing: Bool) -> String {
        switch error as? GymCatalogError {
        case .notAllowed: listing ? "Only moderators can see this list." : "Only moderators can do this."
        case .offline: "No connection. Try again."
        case .signedOut: "Sign in to continue."
        case .unknownTarget: "That one is already gone. Pull to refresh."
        case .placeTaken: "Someone has added this place again since it was removed, so it can't come back."
        default: "Something went wrong. Try again."
        }
    }
}
