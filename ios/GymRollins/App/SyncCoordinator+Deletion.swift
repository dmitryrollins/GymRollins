import Foundation
import GymSync
import os

// Account deletion: the photo steps first, the server step, and only then the wipe.
extension SyncCoordinator {
    /// Deletes the account on the server. Nothing on the phone is wiped until it says yes, so a refusal keeps the
    /// account, the session and the phone's data, and the user can try again. Photos are detached first (the server and
    /// then the phone forget the names), so a refusal after that leaves no listing naming a deleted object: the next
    /// sync uploads the pictures again. Syncing stops meanwhile so it can't do that too soon. The one call site of
    /// `AuthService.deleteAccount`: it hands over the photo steps, without which the server refuses anyone who has a photo.
    func deleteAccount() async throws {
        deletingAccount = true
        defer { deletingAccount = false }
        onSessionEnding()
        debouncer.cancel()
        await dropEngine()
        do {
            try await deleteOnServer(removePhotos.map(forgettingNamesOnDetach))
        } catch {
            refreshEngine()
            onDeletionRefused()
            throw error
        }
        accountSwitchPending = false
        try await wipeLocal(erasingGyms: true)
    }

    /// After the server detached the photos, the phone drops their names too.
    private func forgettingNamesOnDetach(_ photos: AccountPhotoSteps) -> AccountPhotoSteps {
        AccountPhotoSteps(detach: { [weak self] in
            try await photos.detach()
            try await self?.forgetRemotePhotos()
        }, remove: photos.remove)
    }

    private func forgetRemotePhotos() throws {
        do { try store.forgetRemotePhotos() } catch {
            Self.log.error("Forgetting photo names failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
