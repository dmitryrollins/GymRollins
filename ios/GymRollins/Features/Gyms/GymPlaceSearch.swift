import Foundation
import MapKit

/// Gyms on Apple Maps (`GymPlaceMatching` says which places count). Both calls throw when Maps can't be reached;
/// callers show a plain line, not an alert.
@MainActor
protocol GymPlaceSearch {
    func search(query: String, near: GymCoordinate?) async throws -> [GymPlace]
    /// Gyms within 150 m of `coordinate`.
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

/// Each call asks Maps twice at once: for fitness centers, and for every place, since some gyms have no category.
struct MapKitGymPlaceSearch: GymPlaceSearch {
    private static let fitnessCenters = MKPointOfInterestFilter(including: [.fitnessCenter])

    func search(query: String, near: GymCoordinate?) async throws -> [GymPlace] {
        async let tagged = Self.searchPlaces(query, near: near, fitnessCentersOnly: true)
        async let others = Self.searchPlaces(query, near: near, fitnessCentersOnly: false)
        return try await GymPlaceMatching.searchResults(query: query, fitnessCenters: tagged, others: others)
    }

    func nearby(_ coordinate: GymCoordinate) async throws -> [GymPlace] {
        async let tagged = Self.nearbyPlaces(coordinate, fitnessCentersOnly: true)
        async let others = Self.nearbyPlaces(coordinate, fitnessCentersOnly: false)
        return try await GymPlaceMatching.nearbyResults(fitnessCenters: tagged, others: others)
    }

    /// Requests are built here, on the main actor: MapKit's request and filter types aren't Sendable.
    private static func searchPlaces(_ query: String, near: GymCoordinate?,
                                     fitnessCentersOnly: Bool) async throws -> [GymPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.pointOfInterestFilter = fitnessCentersOnly ? fitnessCenters : nil
        request.resultTypes = .pointOfInterest
        if let near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude),
                latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        return try await run(request)
    }

    private static func nearbyPlaces(_ coordinate: GymCoordinate, fitnessCentersOnly: Bool) async throws -> [GymPlace] {
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let request = MKLocalPointsOfInterestRequest(center: center, radius: NearbyGymRule.radiusMeters)
        request.pointOfInterestFilter = fitnessCentersOnly ? fitnessCenters : nil
        return try await run(request)
    }

    /// Maps says "not found" when nothing matched: that is no results, not an outage.
    static func orEmpty(_ search: () async throws -> [GymPlace]) async throws -> [GymPlace] {
        do { return try await search() }
        catch let error as MKError where error.code == .placemarkNotFound { return [] }
    }

    private static func run(_ request: MKLocalSearch.Request) async throws -> [GymPlace] {
        try await orEmpty { places(try await MKLocalSearch(request: request).start().mapItems) }
    }

    private static func run(_ request: MKLocalPointsOfInterestRequest) async throws -> [GymPlace] {
        try await orEmpty { places(try await MKLocalSearch(request: request).start().mapItems) }
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
