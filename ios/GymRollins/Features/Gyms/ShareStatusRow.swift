import GymCore
import GymData
import SwiftUI

/// What a listing's detail says about sharing, worked out from its state: the words, the failure reason, and which
/// actions make sense. Plain data, so the rules are tested without a screen.
struct ShareStatusModel: Equatable {
    enum Action: Equatable { case share, retry, confirm, shareAnyway, sync }

    let text: String
    let reason: String?
    let actions: [Action]
    /// Someone else's listing, and my own once it is on the server, are not removed from here (plan 22 adds the report
    /// path). A share still waiting, stuck or undecided can be taken back.
    let canRemove: Bool
    /// What the confirmation before Delete says will happen.
    let deleteMessage: String
    /// Loads, quantity, note and photo are mine to change only while the listing isn't the shared catalogue's.
    let canEdit: Bool

    init(listing: GymListing, gym: Gym) {
        let isShared = listing.visibility == .shared
        let unsent = Self.isUnsent(listing)
        canRemove = listing.isOwn && (!isShared || unsent)
        deleteMessage = Self.deleteMessage(listing, unsent: unsent)
        canEdit = !isShared && listing.status != .unsupported
        switch listing.uploadState {
        case .failed:
            (text, reason, actions) = ("Couldn't upload", listing.uploadError, [.retry])
        case .queued:
            (text, reason, actions) = ("Waiting to upload", nil, [])
        case .waitingForChoice:
            (text, reason, actions) = ("This gym may already have it", nil, [.shareAnyway])
        case .local, .uploaded:
            reason = nil
            switch listing.visibility {
            case .synced:
                (text, actions) = ("Synced to your account", [])
            case .shared where !listing.isOwn && listing.confirmedByMe:
                (text, actions) = ("You confirmed this", [])
            case .shared where !listing.isOwn:
                (text, actions) = ("Shared at this gym", [.confirm])
            case .shared:
                (text, actions) = ("Shared at this gym", [])
            case .device:
                (text, actions) = ("Only me", gym.isPrivate ? [.sync] : [.share])
            }
        }
    }

    /// A share that has not reached the server: deleting it also takes it out of the upload queue.
    static func isUnsent(_ listing: GymListing) -> Bool {
        [.queued, .failed, .waitingForChoice].contains(listing.uploadState)
    }

    private static func deleteMessage(_ listing: GymListing, unsent: Bool) -> String {
        if unsent { return "It and its photo will be deleted from this phone and won't be shared." }
        if listing.visibility == .synced {
            return "It and its photo will be deleted from this phone and your account. This can't be undone."
        }
        return "It and its photo will be deleted from this phone. This can't be undone."
    }

    static func title(_ action: Action) -> String {
        switch action {
        case .share: "Share with this gym"
        case .retry: "Retry"
        case .confirm: "+1 confirm"
        case .shareAnyway: "No, it's a different one"
        case .sync: "Sync to my account"
        }
    }

    static func identifier(_ action: Action) -> String {
        switch action {
        case .share: "listing.share"
        case .retry: "listing.retry"
        case .confirm: "listing.confirm"
        case .shareAnyway: "listing.shareAnyway"
        case .sync: "listing.sync"
        }
    }
}

/// The sharing state of one listing, with the actions it allows. A share that found the gym already lists the item
/// shows those listings first: "Yes, that's it" confirms one and drops mine.
struct ShareStatusRow: View {
    @Environment(AppEnvironment.self) private var env
    let status: ShareStatusModel
    let duplicates: [RemoteListing]
    let onAction: (ShareStatusModel.Action) -> Void
    let onKeepExisting: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(status.text).font(.headline).foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("listing.shareStatus")
            if let reason = status.reason {
                Text(reason).font(.footnote).foregroundStyle(Theme.destructive)
                    .accessibilityIdentifier("listing.shareReason")
            }
            ForEach(duplicates, id: \.id) { duplicate in existing(duplicate) }
            ForEach(status.actions, id: \.self) { action in button(action) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func button(_ action: ShareStatusModel.Action) -> some View {
        let id = ShareStatusModel.identifier(action)
        if action == .retry || action == .share || action == .sync {
            PrimaryGlassButton(title: ShareStatusModel.title(action), identifier: id) { onAction(action) }
        } else {
            SecondaryGlassButton(title: ShareStatusModel.title(action), identifier: id) { onAction(action) }
        }
    }

    private func existing(_ duplicate: RemoteListing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(Self.name(duplicate, kind: env.gymCatalog.kind(duplicate.kindId)?.name))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                if duplicate.confirmCount > 0 { Badge(text: "\u{2713} \(duplicate.confirmCount)", kind: .success) }
            }
            PrimaryGlassButton(title: "Yes, that's it (+1 confirm)", identifier: "listing.keepExisting.\(duplicate.id.uuidString)") {
                onKeepExisting(duplicate.id)
            }
        }
    }

    static func name(_ listing: RemoteListing, kind: String?) -> String {
        let named = [listing.brand, listing.model].compactMap { $0 }.joined(separator: " ")
        return named.isEmpty ? (kind ?? "Equipment") : named
    }
}
