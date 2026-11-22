import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan 39: "Read activity from Apple Health" is on until the owner turns it off, survives every profile save, and
/// travels with the synced profile.
@MainActor
@Suite struct ProfileReadActivityTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    @Test func itIsOnByDefaultAndSurvivesSaves() throws {
        defer { f.tearDown() }
        #expect(try f.profiles.load().mcpReadActivity)
        try f.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true,
                                         propose: true, autoApply: false, logWorkouts: false, readActivity: false)
        #expect(try !f.profiles.load().mcpReadActivity)
        try f.profiles.save(try f.profiles.load().withLimits("ankle sprain", until: nil))
        #expect(try !f.profiles.load().mcpReadActivity, "saving the whole profile keeps it")
        try f.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true,
                                         propose: true, autoApply: false, logWorkouts: true)
        #expect(try !f.profiles.load().mcpReadActivity, "a change that doesn't name it keeps it")
    }

    @Test func itTravelsWithTheSyncedProfile() throws {
        defer { f.tearDown() }
        try f.profiles.setMcpPermissions(readWorkouts: true, readBody: true, readPlan: true, readGyms: true,
                                         propose: true, autoApply: false, logWorkouts: false, readActivity: false)
        #expect(try f.store.dirtyProfile()?.value.mcpReadActivity == false)
        var remote = ProfileSnapshot()
        remote.mcpReadActivity = true
        try f.store.applyRemote(profile: SyncRow(value: remote, clientUpdatedAt: f.clock.now.addingTimeInterval(60)))
        #expect(try f.profiles.load().mcpReadActivity)
    }
}
