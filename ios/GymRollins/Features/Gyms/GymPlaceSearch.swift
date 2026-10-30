import Foundation
import MapKit

/// Fitness centers on Apple Maps. Both calls throw when Maps can't be reached; callers show a plain line, not an alert.
@MainActor
protocol GymPlaceSearch {
    func search(query: String, near: GymCoordinate?) async throws -> [GymPlace]
    /// Fitness centers within 150 m of `coordinate`.
    func nearby(_ coordinate: GymCoordinate) async throws -> [GymPlace]
}

/// Plain `-uiTesting`: nothing is searched and nothing found, so no test reaches Maps.
struct NoGymPlaceSearch: GymPlaceSearch {
    func search(query: String, near: GymCoordinate?) async throws -> [GymPlace] { [] }
    func nearby(_ coordinate: GymCoordinate) async throws -> [GymPlace] { [] }
}

/// `-fakeGymPlaces`: "Iron Works Gym" 50 m and "Test Fitness" 2 km north of `origin` (the fake location).
struct FakeGymPlaceSearch: GymPlaceSearch {
    let origin: GymCoordinate

    private var places: [GymPlace] {
        func north(_ meters: Double) -> GymCoordinate {
            GymCoordinate(latitude: origin.latitude + meters / 111_320, longitude: origin.longitude)
        }
        return [
            GymPlace(placeId: "fake-iron-works", name: "Iron Works Gym", address: "1 Barbell Way", coordinate: north(50)),
            GymPlace(placeId: "fake-test-fitness", name: "Test Fitness", address: "2 Treadmill Road", coordinate: north(2000)),
        ]
    }

    func search(query: String, near: GymCoordinate?) async throws -> [GymPlace] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return places.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    func nearby(_ coordinate: GymCoordinate) async throws -> [GymPlace] {
        places.filter { coordinate.distance(to: $0.coordinate) <= NearbyGymRule.radiusMeters }
    }
}

struct MapKitGymPlaceSearch: GymPlaceSearch {
    private static let filter = MKPointOfInterestFilter(including: [.fitnessCenter])

    func search(query: String, near: GymCoordinate?) async throws -> [GymPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.pointOfInterestFilter = Self.filter
        request.resultTypes = .pointOfInterest
        if let near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude),
                latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        return Self.places(try await MKLocalSearch(request: request).start().mapItems)
    }

    func nearby(_ coordinate: GymCoordinate) async throws -> [GymPlace] {
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let request = MKLocalPointsOfInterestRequest(center: center, radius: NearbyGymRule.radiusMeters)
        request.pointOfInterestFilter = Self.filter
        return Self.places(try await MKLocalSearch(request: request).start().mapItems)
    }

    /// Items without an identifier can't be remembered, so they are skipped.
    private static func places(_ items: [MKMapItem]) -> [GymPlace] {
        items.compactMap { item in
            guard let id = item.identifier?.rawValue, let name = item.name else { return nil }
            let location = item.location.coordinate
            return GymPlace(placeId: id, name: name, address: item.address?.shortAddress,
                            coordinate: GymCoordinate(latitude: location.latitude, longitude: location.longitude))
        }
    }
}
