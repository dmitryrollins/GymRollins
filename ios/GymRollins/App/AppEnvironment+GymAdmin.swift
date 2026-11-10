import Foundation

extension AppEnvironment {
    /// Asks the server whether this account moderates, once per sign-in. Nothing goes out while signed out.
    func refreshGymAdmin() async {
        let transport = gymSharing.transport
        await gymAdmin.refresh(userId: sharingUserId) { try await transport.isAdmin() }
    }
}
