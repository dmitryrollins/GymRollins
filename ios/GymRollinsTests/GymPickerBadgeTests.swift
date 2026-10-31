import Foundation
import GymData
import SwiftData
import Testing
@testable import GymRollins

/// My gyms' badge for each gym, and which gyms offer "Sync to my account".
@MainActor
@Suite struct GymPickerBadgeTests {
    private func mapsGym(_ rig: GymTestRig) throws -> Gym {
        try rig.env.gyms.addMapsGym(placeId: "P1", name: "Iron", address: nil, latitude: 1, longitude: 2)
    }

    @Test func eachGymHasItsBadgeAndOnlyPrivateOnesOfferSync() throws {
        let rig = try GymTestRig.make()
        let home = try rig.gym("Home")
        let maps = try mapsGym(rig)
        #expect(GymPickerView.badgeText(for: home) == "Only me")
        #expect(GymPickerView.canSync(home))
        try rig.env.gyms.makeSynced(gym: home.id)
        let synced = try #require(try rig.env.gyms.gym(home.id))
        #expect(GymPickerView.badgeText(for: synced) == "Synced")
        #expect(!GymPickerView.canSync(synced))
        #expect(GymPickerView.badgeText(for: maps) == "Only me")
        #expect(!GymPickerView.canSync(maps), "a Maps gym is shared, not synced")
    }

    @Test func aMapsGymTheServerKnowsIsShared() throws {
        let rig = try GymTestRig.make()
        let maps = try mapsGym(rig)
        let id = maps.id
        let context = rig.env.container.mainContext
        try #require(try context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.id == id })).first).remoteId = UUID()
        try context.save()
        #expect(GymPickerView.badgeText(for: try #require(try rig.env.gyms.gym(id))) == "Shared")
    }
}
