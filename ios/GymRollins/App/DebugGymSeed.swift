#if DEBUG
import Foundation
import GymCore
import GymData
import SwiftData

/// DEBUG/UI-test only (`-seedGym`): a private "Home" gym with kettlebells (20 and 24 kg) and a flat bench, no photos.
/// Adds nothing when a gym named "Home" already exists, and returns it either way.
@MainActor
enum DebugGymSeed {
    @discardableResult
    static func apply(context: ModelContext, now: Date) throws -> Gym {
        let gyms = GymRepository(context: context, now: { now })
        if let existing = try gyms.gyms().first(where: { $0.name == "Home" }) { return existing }
        let home = try gyms.addPrivateGym(name: "Home", address: nil)
        try gyms.addListing(NewListing(gymId: home.id, kindId: "kettlebells", loads: .fixed(kg: [20, 24])))
        try gyms.addListing(NewListing(gymId: home.id, kindId: "flat-bench"))
        return home
    }
}
#endif
