import Foundation
import SwiftData

// "Synced to my account": a private gym and its listings travel with the account.
extension GymRepository {
    /// Marks a private gym synced. Its synced listings go up again; its "This phone only" listings stay put.
    public func makeSynced(gym id: UUID) throws {
        let record = try privateGymRecord(id)
        if record.visibilityRaw != GymVisibility.synced.rawValue {
            record.visibilityRaw = GymVisibility.synced.rawValue
            touch(record)
        }
        let synced = GymVisibility.synced.rawValue
        for row in try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.gymId == id }))
        where row.visibilityRaw == synced && row.deletedAt == nil {
            touch(row)
        }
        try context.save()
    }

    /// Marks a listing synced, and its gym with it: a listing can't sync to a gym the server hasn't got.
    public func makeSynced(listing id: UUID) throws {
        guard let record = try listingRecord(id) else { throw GymDataError.invalidInput("Unknown listing.") }
        let gym = try privateGymRecord(record.gymId)
        if gym.visibilityRaw != GymVisibility.synced.rawValue {
            gym.visibilityRaw = GymVisibility.synced.rawValue
            touch(gym)
        }
        record.visibilityRaw = GymVisibility.synced.rawValue
        touch(record)
        try context.save()
    }

    private func privateGymRecord(_ id: UUID) throws -> GymRecord {
        guard let record = try gymRecord(id) else { throw GymDataError.invalidInput("Unknown gym.") }
        guard record.mapsPlaceId == nil else {
            throw GymDataError.invalidInput("A gym from Maps can't be synced to your account.")
        }
        return record
    }
}
