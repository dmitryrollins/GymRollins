import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// Codex P2: Bar & Plates must not rewrite the profile just by opening, must keep precision, and must accept a
/// decimal comma.
@Suite struct BarAndPlatesFormTests {
    private let kgProfile = Profile(unit: .kg, barKg: 20, plateInventory: .standardKg, dumbbellStepKg: 1.25)

    @Test func openingWithoutEditingChangesNothing() throws {
        for profile in [Profile(), kgProfile] {
            #expect(try BarAndPlatesForm(profile: profile).updatedProfile(from: profile) == nil)
        }
    }

    @Test func precisionIsKept() throws {
        let form = BarAndPlatesForm(profile: kgProfile)
        #expect(form.dumbbellStepText == "1.25")
        #expect(form.barText == "20")
        #expect(form.available.contains(1.25))
        #expect(BarAndPlatesForm.format(2.2046) == "2.205")
        #expect(BarAndPlatesForm.format(45) == "45")
        #expect(BarAndPlatesForm.format(0.5) == "0.5")
    }

    @Test func decimalCommaParses() throws {
        var form = BarAndPlatesForm(profile: kgProfile)
        form.dumbbellStepText = "2,5"
        form.barText = "15,5"
        let updated = try #require(try form.updatedProfile(from: kgProfile))
        #expect(abs(updated.dumbbellStepKg - 2.5) < 1e-9)
        #expect(updated.plateInventory.bar == 15.5)
    }

    @Test func togglingAPlateSavesTheInventory() throws {
        var form = BarAndPlatesForm(profile: Profile())
        form.available.remove(2.5)
        let updated = try #require(try form.updatedProfile(from: Profile()))
        #expect(updated.plateInventory.plates == [45, 35, 25, 10, 5])
        #expect(updated.plateInventory.unit == .lb)
    }

    @Test func nonPositiveOrGarbageIsRejected() {
        for text in ["0", "-5", "abc", ""] {
            var form = BarAndPlatesForm(profile: Profile())
            form.barText = text
            #expect(throws: BarAndPlatesForm.Invalid.nonPositive) { try form.updatedProfile(from: Profile()) }
        }
    }
}
