import GymCore
import GymData
import Foundation

/// The words and rules behind My gyms' badges and its "Sync to my account" question.
extension GymPickerView {
    /// Where the gym's equipment lives: only here, in the account, or in the shared catalogue.
    static func badgeText(for gym: Gym) -> String {
        if gym.visibility == .synced { return "Synced" }
        return !gym.isPrivate && gym.remoteId != nil ? "Public gym" : "Only me"
    }

    /// The question before "Sync to my account", with how much goes.
    static func syncPrompt(gymName: String, itemCount: Int) -> (title: String, body: String) {
        let title = "Sync \(gymName)?"
        switch itemCount {
        case 0: return (title, "The gym goes to your account. Only you can see it.")
        case 1: return (title, "The gym and its 1 item, with its photo, go to your account. Only you can see it.")
        default: return (title, "The gym and its \(itemCount) items, with their photos, go to your account. Only you can see them.")
        }
    }

    /// The listings one tap on Sync uploads with the gym: the ones still on this phone only.
    static func itemsToSync(in gymId: UUID, repository: GymRepository) -> Int {
        do { return try repository.listings(gymId: gymId).filter { $0.visibility == .device }.count }
        catch {
            AppEnvironment.log.error("Read gym items failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    static let syncTitle = "Sync to my account"

    /// A private gym that only this phone has. A Maps gym is shared, not synced.
    static func canSync(_ gym: Gym) -> Bool { gym.isPrivate && gym.visibility == .device }
}
