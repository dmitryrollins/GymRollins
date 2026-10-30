import Foundation
import GymCore

/// The chips and length the Build workout sheet starts with, remembered per device.
struct BuildSetup: Codable, Equatable {
    static let key = "gymrollins.buildSetup"

    /// In the order they were tapped.
    var muscles: [BuildMuscle] = []
    var length = BuildLength.medium

    @MainActor
    static func load(from defaults: UserDefaults) -> BuildSetup {
        guard let data = defaults.data(forKey: key) else { return BuildSetup() }
        do { return try JSONDecoder().decode(BuildSetup.self, from: data) }
        catch {
            AppEnvironment.log.error("Read build setup failed: \(error.localizedDescription, privacy: .public)")
            return BuildSetup()
        }
    }

    @MainActor
    func save(to defaults: UserDefaults) {
        do { defaults.set(try JSONEncoder().encode(self), forKey: Self.key) }
        catch { AppEnvironment.log.error("Save build setup failed: \(error.localizedDescription, privacy: .public)") }
    }

    func toggling(_ muscle: BuildMuscle) -> BuildSetup {
        var copy = self
        if let index = muscles.firstIndex(of: muscle) { copy.muscles.remove(at: index) } else { copy.muscles.append(muscle) }
        return copy
    }

    func with(length: BuildLength) -> BuildSetup {
        var copy = self
        copy.length = length
        return copy
    }
}
