import Foundation
import Testing
@testable import GymCore

@Suite struct BuildOptionsTests {
    @Test(arguments: [
        (BuildLength.short, 1, 3), (.short, 3, 3), (.medium, 1, 4), (.medium, 2, 5), (.long, 1, 6), (.long, 4, 6),
    ])
    func slotsPerLength(length: BuildLength, muscles: Int, slots: Int) {
        #expect(length.slots(muscleCount: muscles) == slots)
    }

    @Test func chipsCoverEveryMuscleGroupExactlyOnce() {
        let all = BuildMuscle.allCases.flatMap(\.groups)
        #expect(all.count == MuscleGroup.allCases.count)
        #expect(Set(all) == Set(MuscleGroup.allCases))
    }

    @Test func requestDropsDuplicateChipsAndKeepsTheirOrder() {
        let request = BuildRequest(muscles: [.back, .arms, .back], length: .medium, date: .distantPast)
        #expect(request.muscles == [.back, .arms])
    }

    @Test func stableHashIsFnv1aAndDaysAreUtc() {
        #expect(StableHash.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(StableHash.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(StableHash.day(of: Date(timeIntervalSince1970: 86_400 * 3 + 86_399)) == 3)
    }
}
