import Foundation
import GymCore
import Observation

/// The owner's own rest between working sets, by exercise id: a change on one exercise sticks to it in every workout.
/// Kept on this iPhone only (UserDefaults): it never syncs and agents don't see it. An exercise without one rests its
/// suggestion (`ExerciseRest`), so the store holds only the rests that differ from it.
@MainActor
@Observable
final class ExerciseRestStore {
    static let key = "exerciseRestSeconds"
    private(set) var seconds: [String: Int]
    @ObservationIgnored private let defaults: UserDefaults

    /// Loads the saved rests; a value outside `DomainLimits.restSec` is dropped.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.key) ?? [:]
        self.seconds = stored.compactMapValues { ($0 as? Int).flatMap { DomainLimits.restSec.contains($0) ? $0 : nil } }
    }

    func custom(_ id: String) -> Int? { seconds[id] }

    /// Keeps `value` as the exercise's rest, or forgets it when nil.
    func set(_ value: Int?, for id: String) {
        guard seconds[id] != value else { return }
        var updated = seconds
        updated[id] = value
        seconds = updated
        save()
    }

    /// Forgets every exercise's rest (the local data was erased).
    func clear() {
        seconds = [:]
        save()
    }

    private func save() {
        if seconds.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(seconds, forKey: Self.key) }
    }
}
