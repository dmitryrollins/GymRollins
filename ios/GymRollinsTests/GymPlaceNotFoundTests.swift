import MapKit
import Testing
@testable import GymRollins

/// Maps says "not found" when nothing matched: that is an empty list, while a real outage still throws.
@Suite struct GymPlaceNotFoundTests {
    @Test func placemarkNotFoundIsNoResults() async throws {
        let found = try await MapKitGymPlaceSearch.orEmpty { throw MKError(.placemarkNotFound) }
        #expect(found.isEmpty)
    }

    @Test func otherMapsErrorsStillThrow() async {
        await #expect(throws: MKError.self) {
            _ = try await MapKitGymPlaceSearch.orEmpty { throw MKError(.serverFailure) }
        }
    }

    @Test func resultsPassThrough() async throws {
        let place = GymPlace(placeId: "p", name: "Iron", address: "1 Way", coordinate: GymCoordinate(latitude: 1, longitude: 2))
        let found = try await MapKitGymPlaceSearch.orEmpty { [place] }
        #expect(found == [place])
    }
}
