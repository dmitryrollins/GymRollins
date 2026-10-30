import CoreLocation
import Foundation
import GymCore
import GymData

struct GymCoordinate: Sendable, Hashable {
    let latitude: Double
    let longitude: Double

    func distance(to other: GymCoordinate) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

/// A fitness center found on Apple Maps. `placeId` is `MKMapItem.identifier`.
struct GymPlace: Sendable, Hashable, Identifiable {
    let placeId: String
    let name: String
    let address: String?
    let coordinate: GymCoordinate
    var id: String { placeId }
}

/// A gym within reach of the phone: one of My gyms, or a Maps place that isn't saved yet.
struct NearbyGym: Equatable, Identifiable {
    enum Target: Equatable {
        case saved(Gym)
        case place(GymPlace)
    }

    let target: Target
    let distanceMeters: Double

    var id: String {
        switch target {
        case .saved(let gym): gym.id.uuidString
        case .place(let place): place.placeId
        }
    }

    var name: String {
        switch target {
        case .saved(let gym): gym.name
        case .place(let place): place.name
        }
    }

    var address: String? {
        switch target {
        case .saved(let gym): gym.address
        case .place(let place): place.address
        }
    }
}

/// Which gym, if any, the phone is at, and how often Today may look.
enum NearbyGymRule {
    static let radiusMeters = 150.0
    static let recheckInterval: TimeInterval = 30 * 60

    /// Whether Today may ask for a location fix again. A last check in the future (the clock was set back) is stale.
    static func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked, lastChecked <= now else { return true }
        return now.timeIntervalSince(lastChecked) >= recheckInterval
    }

    /// The closest gym within 150 m that isn't the current one. My gyms win a tie with a Maps place, and a Maps place
    /// that one of My gyms already stores counts once, as that gym.
    static func nearest(to here: GymCoordinate, currentGymId: UUID?, myGyms: [Gym], places: [GymPlace]) -> NearbyGym? {
        let known = Set(myGyms.compactMap(\.mapsPlaceId))
        let saved: [NearbyGym] = myGyms.compactMap { gym in
            guard gym.id != currentGymId, let latitude = gym.latitude, let longitude = gym.longitude else { return nil }
            return NearbyGym(target: .saved(gym), distanceMeters: here.distance(to: .init(latitude: latitude, longitude: longitude)))
        }
        let unsaved: [NearbyGym] = places.compactMap { place in
            guard !known.contains(place.placeId) else { return nil }
            return NearbyGym(target: .place(place), distanceMeters: here.distance(to: place.coordinate))
        }
        // `saved` comes first, and `min(by:)` keeps the earlier of two equal distances.
        return (saved + unsaved).filter { $0.distanceMeters <= radiusMeters }.min { $0.distanceMeters < $1.distanceMeters }
    }

    /// "164 ft" / "0.4 mi" for pounds users, "50 m" / "1.5 km" for kilograms users.
    static func distanceText(meters: Double, unit: WeightUnit) -> String {
        switch unit {
        case .kg:
            return meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1000)
        case .lb:
            let feet = meters * 3.28084
            return feet < 528 ? "\(Int(feet.rounded())) ft" : String(format: "%.1f mi", meters / 1609.344)
        }
    }
}
