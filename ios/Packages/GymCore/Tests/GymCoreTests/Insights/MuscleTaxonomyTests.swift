import Foundation
import Testing
@testable import GymCore

struct MuscleTaxonomyTests {
    typealias F = InsightsFixture

    @Test func sixteenGroupsWithStableIds() {
        #expect(MuscleGroup.allCases.count == 16)
        #expect(MuscleGroup.upperBack.rawValue == "upper_back")
        #expect(MuscleGroup.lowerBack.displayName == "Lower back")
        #expect(Set(MuscleGroup.allCases.filter(\.isLeg)) ==
                [.glutes, .quads, .hamstrings, .calves, .adductors, .abductors])
    }

    @Test func defaultTargetsMajorAndSmall() {
        #expect(MuscleGroup.chest.defaultTarget == SetTargetRange(min: 10, max: 20))
        #expect(MuscleGroup.lats.defaultTarget == SetTargetRange(min: 10, max: 20))
        #expect(MuscleGroup.biceps.defaultTarget == SetTargetRange(min: 6, max: 12))
        #expect(MuscleGroup.calves.defaultTarget == SetTargetRange(min: 6, max: 12))
        #expect(MuscleGroup.allCases.filter(\.isMajor) ==
                [.chest, .shoulders, .upperBack, .lats, .glutes, .quads, .hamstrings])
    }

    @Test func benchIsChestPrimaryTricepsShoulderSecondary() {
        let c = MuscleTaxonomy.contributions(for: F.bench)
        #expect(c == [MuscleContribution(group: .chest, weight: 1, isPrimary: true),
                      MuscleContribution(group: .triceps, weight: 0.5, isPrimary: false),
                      MuscleContribution(group: .shoulders, weight: 0.5, isPrimary: false)])
    }

    @Test func squatSecondariesMapToLegGroupsAndCore() {
        let groups = MuscleTaxonomy.contributions(for: F.squat).map(\.group)
        #expect(groups == [.glutes, .quads, .hamstrings, .calves, .abs])
    }

    @Test func secondarySameGroupCountsOnceAndPrimaryWins() {
        let ex = Exercise(id: "x", name: "x", bodyPart: "shoulders", equipment: "cable", target: "delts",
                          secondary: ["trapezius", "traps", "deltoids", "rear deltoids"])
        let c = MuscleTaxonomy.contributions(for: ex)
        #expect(c == [MuscleContribution(group: .shoulders, weight: 1, isPrimary: true),
                      MuscleContribution(group: .traps, weight: 0.5, isPrimary: false)])
    }

    @Test func cardioAndUnknownContributeNothing() {
        #expect(MuscleTaxonomy.contributions(for: F.run).isEmpty)
        let neck = Exercise(id: "n", name: "neck", bodyPart: "neck", equipment: "body weight",
                            target: "sternocleidomastoid")
        #expect(MuscleTaxonomy.contributions(for: neck) == [MuscleContribution(group: .traps, weight: 1, isPrimary: true)])
        let mystery = Exercise(id: "m", name: "m", bodyPart: "other", equipment: "x", target: "mystery")
        #expect(MuscleTaxonomy.contributions(for: mystery).isEmpty)
    }

    @Test func customExerciseFallsBackToBodyPartSplittingThePrimaryWeight() {
        let c = MuscleTaxonomy.contributions(for: F.customLegs)
        #expect(c.map(\.group) == [.quads, .hamstrings, .glutes])
        #expect(c.allSatisfy { abs($0.weight - 1.0 / 3) < 1e-9 && $0.isPrimary })
        let chest = Exercise(id: "custom-1", name: "c", bodyPart: "chest", equipment: "x", target: "chest",
                             isCustom: true)
        #expect(MuscleTaxonomy.contributions(for: chest) == [MuscleContribution(group: .chest, weight: 1, isPrimary: true)])
    }

    @Test func everyLibraryTargetAndSecondaryIsMapped() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GymRollins/Resources/exercises.json")
        let library = try JSONDecoder().decode([Exercise].self, from: Data(contentsOf: url))
        let unmappedTargets = Set(library.map(\.target)).filter {
            $0 != "cardiovascular system" && MuscleTaxonomy.groups(forTarget: $0).isEmpty
        }
        #expect(unmappedTargets.isEmpty, "unmapped targets: \(unmappedTargets)")
        let ignoredSecondaries: Set<String> = []
        let unmappedSecondaries = Set(library.flatMap(\.secondary)).filter {
            MuscleTaxonomy.group(forMuscle: $0) == nil && !ignoredSecondaries.contains($0)
        }
        #expect(unmappedSecondaries.isEmpty, "unmapped secondaries: \(unmappedSecondaries)")
    }
}
