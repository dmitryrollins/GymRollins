import CoreLocation
import Foundation

/// One location fix, asked for when needed. Never throws: no permission, no fix or a failed request is nil.
@MainActor
protocol GymLocator {
    /// Whether location is already allowed, so Today can look without ever showing a prompt.
    var isAuthorized: Bool { get }
    /// The phone's position. With `askingPermission`, a first request shows the system prompt and waits for the answer;
    /// without it, an undecided status gives nil.
    func locate(askingPermission: Bool) async -> GymCoordinate?
}

/// No position at all: UI tests without `-fakeLocation` and devices that can't locate.
struct UnavailableGymLocator: GymLocator {
    var isAuthorized: Bool { false }
    func locate(askingPermission: Bool) async -> GymCoordinate? { nil }
}

/// `-fakeLocation`: always here, with permission treated as granted.
struct FakeGymLocator: GymLocator {
    let coordinate: GymCoordinate
    var isAuthorized: Bool { true }
    func locate(askingPermission: Bool) async -> GymCoordinate? { coordinate }
}

/// Core Location's one-shot `requestLocation()` and permission prompt, as async calls. Delegate callbacks arrive on
/// the main thread (the manager is made there) and hop onto the main actor with plain values; each waiting
/// continuation is taken out of its list before it is resumed, so none can be resumed twice.
@MainActor
final class CoreLocationGymLocator: NSObject, GymLocator, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var permissionWaiters: [CheckedContinuation<Void, Never>] = []
    private var locationWaiters: [CheckedContinuation<GymCoordinate?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool { Self.allows(manager.authorizationStatus) }

    func locate(askingPermission: Bool) async -> GymCoordinate? {
        if manager.authorizationStatus == .notDetermined {
            guard askingPermission else { return nil }
            await withCheckedContinuation { continuation in
                permissionWaiters.append(continuation)
                if permissionWaiters.count == 1 { manager.requestWhenInUseAuthorization() }
            }
            // The prompt may still be answered "Don't allow".
        }
        guard isAuthorized else { return nil }
        return await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 { manager.requestLocation() }
        }
    }

    private static func allows(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    private func permissionAnswered() {
        let waiters = permissionWaiters
        permissionWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func finish(_ coordinate: GymCoordinate?) {
        let waiters = locationWaiters
        locationWaiters = []
        waiters.forEach { $0.resume(returning: coordinate) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        Task { @MainActor in self.permissionAnswered() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last.map {
            GymCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        Task { @MainActor in self.finish(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
