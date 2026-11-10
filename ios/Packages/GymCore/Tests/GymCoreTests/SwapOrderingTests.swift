import Testing
@testable import GymCore

@Suite struct SwapOrderingTests {
    private func ex(_ id: String, _ name: String, target: String, bodyPart: String = "chest",
                    equipment: String = "dumbbell") -> Exercise {
        Exercise(id: id, name: name, bodyPart: bodyPart, equipment: equipment, target: target)
    }

    @Test func sameTargetFirstThenSameBodyPartEachByLoggedCountThenName() {
        let current = ex("cur", "Current", target: "pectorals")
        let list = [current, ex("t2", "B Press", target: "pectorals"), ex("t1", "A Press", target: "pectorals"),
                    ex("b1", "Serratus Punch", target: "serratus anterior"),
                    ex("o1", "Curl", target: "biceps", bodyPart: "upper arms")]
        let ordered = SwapOrdering.candidates(for: current, in: list, loggedCounts: ["t2": 4, "b1": 1])
        #expect(ordered.map(\.id) == ["t2", "t1", "b1"])
    }

    @Test func barbellLoadedEquipment() {
        #expect(ex("a", "A", target: "x", equipment: "ez barbell").isBarbellLoaded)
        #expect(ex("b", "B", target: "x", equipment: "smith machine").isBarbellLoaded)
        #expect(!ex("c", "C", target: "x", equipment: "dumbbell").isBarbellLoaded)
    }
}
