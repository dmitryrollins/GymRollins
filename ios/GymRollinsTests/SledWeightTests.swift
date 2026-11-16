import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

/// A plate-loaded sled (45° leg press, hack squat) starts from the sled's empty weight, not the bar: 100 lb (45 kg)
/// until it is changed in Bar & Plates, kept on this phone.
@Suite struct SledWeightTests {
    private func freshDefaults() -> UserDefaults {
        let name = "SledWeightTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func unsetIsAHundredPoundsOrFortyFiveKilograms() {
        let defaults = freshDefaults()
        #expect(abs(UnitConverter.fromKg(SledWeight.kg(defaults, unit: .lb), to: .lb) - 100) < 1e-9)
        #expect(SledWeight.kg(defaults, unit: .kg) == 45)
    }

    @Test func aSavedWeightWins() {
        let defaults = freshDefaults()
        SledWeight.save(kg: 50, defaults)
        #expect(SledWeight.kg(defaults, unit: .lb) == 50)
        #expect(SledWeight.kg(defaults, unit: .kg) == 50)
    }

    @Test func theSledTakesTheBarsPlace() {
        let inventory = SledWeight.inventory(.standardLb, sledKg: UnitConverter.toKg(100, from: .lb))
        #expect(abs(inventory.bar - 100) < 1e-9)
        #expect(inventory.plates == PlateInventory.standardLb.plates)
        // 225 lb on a 100 lb sled: 62.5 lb a side, in the fewest plates (on a 45 lb bar it would be two 45s).
        let load = PlateCalculator.load(targetKg: UnitConverter.toKg(225, from: .lb), inventory: inventory)
        #expect(load.perSide == [35, 25, 2.5])
        #expect(load.remainder == 0)
    }

    @Test func theFormShowsAndParsesTheSled() throws {
        let profile = Profile()
        let hundred = UnitConverter.toKg(100, from: .lb)
        var form = BarAndPlatesForm(profile: profile, sledKg: hundred)
        #expect(form.sledText == "100")
        #expect(try form.updatedSledKg(unit: .lb, currentKg: hundred) == nil)
        form.sledText = "112,5"
        let updated = try #require(try form.updatedSledKg(unit: .lb, currentKg: hundred))
        #expect(abs(updated - UnitConverter.toKg(112.5, from: .lb)) < 1e-9)
        // A counterbalanced sled weighs nothing.
        form.sledText = "0"
        #expect(try form.updatedSledKg(unit: .lb, currentKg: hundred) == 0)
        for text in ["-5", "abc", ""] {
            form.sledText = text
            #expect(throws: BarAndPlatesForm.Invalid.nonPositive) {
                try form.updatedSledKg(unit: .lb, currentKg: hundred)
            }
        }
        // The sled isn't part of the profile: changing it alone writes no profile.
        form.sledText = "120"
        #expect(try form.updatedProfile(from: profile) == nil)
    }

    @Test func aKilogramProfileShowsASavedPoundSledWithoutRewritingIt() throws {
        let kgProfile = Profile(unit: .kg, barKg: 20, plateInventory: .standardKg, dumbbellStepKg: 1.25)
        let hundredLb = UnitConverter.toKg(100, from: .lb)
        let form = BarAndPlatesForm(profile: kgProfile, sledKg: hundredLb)
        #expect(form.sledText == "45.359")
        #expect(try form.updatedSledKg(unit: .kg, currentKg: hundredLb) == nil)
    }
}
