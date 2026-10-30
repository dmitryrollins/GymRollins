import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct NearbyGymRuleTests {
    /// Held for the whole test: the store goes away with the rig.
    private let rig: GymTestRig
    private let here = GymCoordinate(latitude: 40.0, longitude: -74.0)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws { rig = try GymTestRig.make() }

    /// A point `meters` north of `here`.
    private func north(_ meters: Double) -> GymCoordinate {
        GymCoordinate(latitude: here.latitude + meters / 111_320, longitude: here.longitude)
    }

    private func place(_ id: String, meters: Double) -> GymPlace {
        GymPlace(placeId: id, name: "Place \(id)", address: nil, coordinate: north(meters))
    }

    private func saved(_ name: String, meters: Double?, placeId: String? = nil) throws -> Gym {
        let gyms = rig.env.gyms
        guard let meters else { return try gyms.addPrivateGym(name: name, address: nil) }
        let at = north(meters)
        return try gyms.addMapsGym(placeId: placeId ?? "saved-\(name)", name: name, address: nil,
                                   latitude: at.latitude, longitude: at.longitude)
    }

    @Test func findsTheNearestWithin150m() throws {
        let found = NearbyGymRule.nearest(to: here, currentGymId: nil, myGyms: [],
                                          places: [place("far", meters: 140), place("near", meters: 40)])
        #expect(found?.id == "near")
        #expect(abs((found?.distanceMeters ?? 0) - 40) < 2)
    }

    @Test func ignoresTheCurrentGym() throws {
        let current = try saved("Current", meters: 10)
        let other = try saved("Other", meters: 80)
        let found = NearbyGymRule.nearest(to: here, currentGymId: current.id, myGyms: [current, other], places: [])
        #expect(found?.target == .saved(other))
    }

    @Test func ignoresGymsWithoutCoordinates() throws {
        let privateGym = try saved("Home", meters: nil)
        #expect(NearbyGymRule.nearest(to: here, currentGymId: nil, myGyms: [privateGym], places: []) == nil)
    }

    @Test func prefersMyGymsOverMapsPlacesAtTheSameDistance() throws {
        let mine = try saved("Mine", meters: 60)
        let found = NearbyGymRule.nearest(to: here, currentGymId: nil, myGyms: [mine],
                                          places: [place("same", meters: 60)])
        #expect(found?.target == .saved(mine))
    }

    @Test func matchesAMapsPlaceAlreadyInMyGymsOnce() throws {
        let mine = try saved("Iron", meters: 30, placeId: "p1")
        let found = NearbyGymRule.nearest(to: here, currentGymId: nil, myGyms: [mine],
                                          places: [place("p1", meters: 30)])
        #expect(found?.target == .saved(mine))
        // And when that gym is the current one, its Maps place isn't suggested either.
        #expect(NearbyGymRule.nearest(to: here, currentGymId: mine.id, myGyms: [mine],
                                      places: [place("p1", meters: 30)]) == nil)
    }

    @Test func throttlesTo30Minutes() {
        #expect(NearbyGymRule.isDue(lastChecked: nil, now: now))
        #expect(!NearbyGymRule.isDue(lastChecked: now.addingTimeInterval(-29 * 60), now: now))
        #expect(NearbyGymRule.isDue(lastChecked: now.addingTimeInterval(-30 * 60), now: now))
        // A clock set back must not block checks until it catches up.
        #expect(NearbyGymRule.isDue(lastChecked: now.addingTimeInterval(60), now: now))
    }

    @Test func nothingFarAway() throws {
        let mine = try saved("Far", meters: 400)
        #expect(NearbyGymRule.nearest(to: here, currentGymId: nil, myGyms: [mine],
                                      places: [place("far", meters: 151), place("farther", meters: 2000)]) == nil)
    }

    @Test func distanceTextFollowsTheProfileUnit() {
        #expect(NearbyGymRule.distanceText(meters: 50, unit: .kg) == "50 m")
        #expect(NearbyGymRule.distanceText(meters: 1500, unit: .kg) == "1.5 km")
        #expect(NearbyGymRule.distanceText(meters: 50, unit: .lb) == "164 ft")
        #expect(NearbyGymRule.distanceText(meters: 1609.344, unit: .lb) == "1.0 mi")
    }
}
