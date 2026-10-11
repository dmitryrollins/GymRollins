import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@MainActor
@Suite struct ProfileSetupInputTests {
    @Test(arguments: ["82,5", "82.5", " 82.5 "])
    func parsesLocalizedBodyweightHeightAndGoal(text: String) throws {
        let input = try ProfileSetupInput.parse(bodyweight: text, height: text.replacingOccurrences(of: "82", with: "180"),
                                                goalWeight: text, unit: .kg).get()
        #expect(input.bodyweightKg == 82.5)
        #expect(input.heightCm == 180.5)
        #expect(input.goalWeightKg == 82.5)
    }

    @Test func wholeNumberWithSpacesAndLbConversion() throws {
        let input = try ProfileSetupInput.parse(bodyweight: " 82 ", height: "", goalWeight: " ", unit: .lb).get()
        #expect(abs(input.bodyweightKg - UnitConverter.toKg(82, from: .lb)) < 1e-9)
        #expect(input.heightCm == nil)
        #expect(input.goalWeightKg == nil)
    }

    @Test func mistypedOptionalFieldsAreErrorsNotNil() {
        #expect(ProfileSetupInput.parse(bodyweight: "82", height: "18o", goalWeight: "", unit: .kg)
            == .failure(.init(message: "Enter a valid height in cm.")))
        #expect(ProfileSetupInput.parse(bodyweight: "82", height: "", goalWeight: "8x", unit: .kg)
            == .failure(.init(message: "Enter a valid goal weight.")))
        #expect(ProfileSetupInput.parse(bodyweight: "", height: "", goalWeight: "", unit: .kg)
            == .failure(.init(message: "Enter your bodyweight.")))
    }

    /// Picking kg sets the 20 kg bar with the kg plates: 60 kg = bar + 20 per side, after a save/reload.
    @Test func kgStandardEquipmentLoadsSixtyAsBarPlusTwentyPerSide() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]))
        let profile = Profile().withStandardEquipment(for: .kg)
        #expect(profile.barKg == 20)
        try env.profiles.save(profile)
        env.reloadProfile()
        #expect(env.profile.barKg == 20)
        #expect(env.profile.plateInventory.bar == 20)
        let load = PlateCalculator.load(targetKg: 60, inventory: env.profile.plateInventory)
        #expect(load.perSide == [20])
        #expect(load.total == 60)

        let lb = env.profile.withStandardEquipment(for: .lb)
        #expect(lb.plateInventory == .standardLb)
        #expect(abs(lb.barKg - UnitConverter.toKg(45, from: .lb)) < 1e-9)
    }

    /// Continue -> Back -> Continue (twice) leaves exactly one onboarding weigh-in holding the latest value.
    @Test func revisitingProfileSetupUpdatesTheOneWeighIn() throws {
        let env = try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting"]))
        let before = try env.body.entries(since: nil).count
        var id = try OnboardingWeighIn.save(weightKg: 80, date: env.now(), reusing: nil, in: env.body)
        id = try OnboardingWeighIn.save(weightKg: 81, date: env.now(), reusing: id, in: env.body)
        id = try OnboardingWeighIn.save(weightKg: 82.5, date: env.now(), reusing: id, in: env.body)
        let entries = try env.body.entries(since: nil)
        #expect(entries.count == before + 1)
        #expect(entries.filter { $0.id == id }.map(\.weightKg) == [82.5])
    }
}
