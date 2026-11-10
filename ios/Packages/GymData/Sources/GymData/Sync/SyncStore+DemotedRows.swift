import Foundation
import GymCore
import SwiftData

// Rows a sign-out turned into "This phone only" rows keep the id the server knows them by. The next sign-in settles
// them: the same account gets its rows back, any other account gets rows that can't collide with the first one's.
extension SyncStore {
    private static let gymMovesKey = "gymrollins.sync.gymMoves"

    /// Run at sign-in, once the account owns this phone's data and before syncing starts.
    ///
    /// - The account the rows were demoted from: a gym goes back to `synced` (clean unless it had an unpushed edit),
    ///   so the pull applies to it and to its listings; a listing with an unpushed edit goes back to `synced` and
    ///   dirty, so the edit is pushed; a listing demoted from a queued share stays on the phone.
    /// - Any other account: the row gets a new id and loses its server fields. Listings follow their gym, and
    ///   workouts keep their links.
    ///
    /// Returns the gyms' old ids mapped to their new ones, for the app to move its current-gym pointer.
    @discardableResult
    public func settleDemotedRows(for userId: UUID) throws -> [UUID: UUID] {
        var gymMoves: [UUID: UUID] = [:]
        var listingMoves: [UUID: UUID] = [:]
        var restored = false
        for gym in try context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.demotedOwnerId != nil })) {
            if gym.demotedOwnerId == userId {
                gym.visibilityRaw = GymVisibility.synced.rawValue
                gym.dirty = gym.demotedDirty
                restored = true
            } else {
                let newId = UUID()
                gymMoves[gym.id] = newId
                try moveGym(gym, to: newId)
            }
            gym.demotedOwnerId = nil
            gym.demotedDirty = false
        }
        for listing in try context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.demotedOwnerId != nil })) {
            if listing.demotedOwnerId == userId {
                if listing.demotedDirty {
                    listing.visibilityRaw = GymVisibility.synced.rawValue
                    listing.dirty = true
                    restored = true
                }
            } else {
                let newId = UUID()
                listingMoves[listing.id] = newId
                listing.id = newId
            }
            listing.demotedOwnerId = nil
            listing.demotedDirty = false
        }
        try repointWorkouts(listings: listingMoves)
        // Cached public listings were read for whoever was signed in before, so "mine" and "confirmed by me" are stale.
        for gym in try context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.mapsPlaceId != nil })) {
            gym.catalogRefreshedAt = nil
        }
        // The pull has to read the restored rows again, whatever the cursors say.
        if restored {
            clearCursor(for: .gyms)
            clearCursor(for: .gymListings)
        }
        try context.save()
        return gymMoves
    }

    /// Gym ids that changed in a pull (a server tombstone for a gym that still held "This phone only" listings),
    /// old to new. The app moves its pointer to them, once.
    public func takeGymMoves() -> [UUID: UUID] {
        let moves = pendingGymMoves()
        defaults.removeObject(forKey: Self.gymMovesKey)
        return moves
    }

    func recordGymMove(from old: UUID, to new: UUID) {
        var moves = pendingGymMoves().mapValues { $0 == old ? new : $0 }
        moves[old] = new
        let encoded = Dictionary(uniqueKeysWithValues: moves.map { ($0.key.uuidString, $0.value.uuidString) })
        defaults.set(encoded, forKey: Self.gymMovesKey)
    }

    /// Gives the gym a new id; its listings and the workouts done there follow.
    func moveGym(_ gym: GymRecord, to newId: UUID) throws {
        let old = gym.id
        for listing in try context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.gymId == old })) {
            listing.gymId = newId
        }
        for workout in try context.fetch(FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.gymId == old })) {
            workout.gymId = newId
        }
        gym.id = newId
    }

    private func pendingGymMoves() -> [UUID: UUID] {
        let stored = defaults.dictionary(forKey: Self.gymMovesKey) as? [String: String] ?? [:]
        return stored.reduce(into: [:]) { result, pair in
            if let old = UUID(uuidString: pair.key), let new = UUID(uuidString: pair.value) { result[old] = new }
        }
    }

    /// A workout's gym link is moved by `moveGym`; the listing each entry used is moved here, in the entry rows and in
    /// the workout's cached copy of them.
    private func repointWorkouts(listings: [UUID: UUID]) throws {
        guard !listings.isEmpty else { return }
        for entry in try context.fetch(FetchDescriptor<WorkoutEntryRecord>(
            predicate: #Predicate { $0.gymListingId != nil })) {
            if let id = entry.gymListingId, let new = listings[id] { entry.gymListingId = new }
        }
        for workout in try context.fetch(FetchDescriptor<WorkoutRecord>()) {
            guard let data = workout.entriesData, var cached = try? JSONDecoder().decode([WorkoutEntry].self, from: data),
                  cached.contains(where: { $0.gymListingId.map(listings.keys.contains) ?? false }) else { continue }
            cached = try cached.map { entry in
                try entry.with(gymListingId: entry.gymListingId.flatMap { listings[$0] } ?? entry.gymListingId)
            }
            workout.entriesData = try JSONEncoder().encode(cached)
        }
    }
}
