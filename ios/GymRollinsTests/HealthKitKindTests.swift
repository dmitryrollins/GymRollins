import GymCore
import GymHealth
import HealthKit
import Testing

/// Plan 39: HealthKit's workout types map to GymRollins' kind slugs (Workout app names), and anything else is "other".
@Suite struct HealthKitKindTests {
    @Test(arguments: [
        (HKWorkoutActivityType.walking, "walking"), (.running, "running"), (.cycling, "cycling"),
        (.highIntensityIntervalTraining, "hiit"), (.traditionalStrengthTraining, "traditional_strength"),
        (.functionalStrengthTraining, "functional_strength"), (.cooldown, "cooldown"), (.socialDance, "dance"),
        (.downhillSkiing, "skiing"), (.wheelchairRunPace, "running"), (.archery, "other"), (.other, "other"),
    ])
    func mapsToItsSlug(type: HKWorkoutActivityType, slug: String) {
        #expect(HealthKitStore.kindSlug(type) == slug)
    }

    @Test func everySlugItWritesIsAKnownKind() {
        let types: [HKWorkoutActivityType] = [
            .walking, .running, .cycling, .highIntensityIntervalTraining, .yoga, .swimming,
            .traditionalStrengthTraining, .functionalStrengthTraining, .elliptical, .rowing, .hiking, .cardioDance,
            .coreTraining, .pilates, .cooldown, .stairs, .jumpRope, .mixedCardio, .crossTraining, .flexibility,
            .mindAndBody, .tennis, .soccer, .basketball, .boxing, .kickboxing, .martialArts, .climbing,
            .snowboarding, .golf, .bowling,
        ]
        #expect(types.allSatisfy { OutsideWorkoutKind(rawValue: HealthKitStore.kindSlug($0)) != nil })
    }
}
