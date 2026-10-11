import Foundation
import Testing
@testable import GymWatchLink

@Suite struct CrownStepperTests {
    // 45 lb bar + 5 lb smallest plate: totals 45, 55, 65… (grid 5 + k × 10).
    let barbellLb = WatchLoadGrid(unit: .lb, step: 10, offset: 5)
    let dumbbellLb = WatchLoadGrid(unit: .lb, step: 2.5, offset: 0)
    let barbellKg = WatchLoadGrid(unit: .kg, step: 2.5, offset: 0)

    @Test func stepsAlongTheLoadableGrid() {
        #expect(CrownStepper.weight(135, steppedBy: 1, grid: barbellLb) == 145)
        #expect(CrownStepper.weight(135, steppedBy: -2, grid: barbellLb) == 115)
        #expect(CrownStepper.weight(60, steppedBy: 1, grid: barbellKg) == 62.5)
        #expect(CrownStepper.weight(25, steppedBy: -1, grid: dumbbellLb) == 22.5)
    }

    @Test func noMovementKeepsAnOffGridPlannedWeight() {
        #expect(CrownStepper.weight(61.2, steppedBy: 0, grid: barbellKg) == 61.2)
    }

    @Test func anOffGridWeightSnapsToTheNeighbourInTheCrownsDirection() {
        #expect(CrownStepper.weight(61.2, steppedBy: 1, grid: barbellKg) == 62.5)
        #expect(CrownStepper.weight(61.2, steppedBy: -1, grid: barbellKg) == 60)
        #expect(CrownStepper.weight(61.2, steppedBy: 2, grid: barbellKg) == 65)
        #expect(CrownStepper.weight(140, steppedBy: -1, grid: barbellLb) == 135)
    }

    @Test func neverGoesBelowZeroOrTheGridStart() {
        #expect(CrownStepper.weight(5, steppedBy: -3, grid: barbellLb) == 5)
        #expect(CrownStepper.weight(2.5, steppedBy: -5, grid: dumbbellLb) == 0)
        #expect(CrownStepper.weight(0, steppedBy: -1, grid: barbellKg) == 0)
    }

    @Test func survivesFloatDrift() {
        // 61.235 kg → lb → back produces values like 134.99999999; still one clean step.
        #expect(CrownStepper.weight(134.999_999_9, steppedBy: 1, grid: barbellLb) == 145)
        #expect(CrownStepper.weight(0.1 + 0.2, steppedBy: 1, grid: WatchLoadGrid(unit: .kg, step: 0.1, offset: 0))
            .isApproximately(0.4))
    }

    @Test func aZeroStepGridNeverMoves() {
        #expect(CrownStepper.weight(40, steppedBy: 3, grid: WatchLoadGrid(unit: .kg, step: 0, offset: 0)) == 40)
    }

    @Test func repsStayInRange() {
        #expect(CrownStepper.reps(8, steppedBy: 2) == 10)
        #expect(CrownStepper.reps(1, steppedBy: -5) == 0)
        #expect(CrownStepper.reps(99, steppedBy: 5) == CrownStepper.maxReps)
    }
}

@Suite struct WatchCommandLedgerTests {
    @Test func remembersAppliedCommands() {
        let id = UUID()
        let ledger = WatchCommandLedger().recording(id)
        #expect(ledger.contains(id))
        #expect(!WatchCommandLedger().contains(id))
    }

    @Test func recordingTwiceKeepsOneEntry() {
        let id = UUID()
        #expect(WatchCommandLedger().recording(id).recording(id).ids == [id])
    }

    @Test func forgetsTheOldestBeyondCapacity() {
        let ids = (0..<5).map { _ in UUID() }
        let ledger = ids.reduce(WatchCommandLedger(capacity: 3)) { $0.recording($1) }
        #expect(ledger.ids == Array(ids.suffix(3)))
        #expect(!ledger.contains(ids[0]))
    }

    @Test func persistsAsJSON() throws {
        let ledger = WatchCommandLedger().recording(UUID())
        let data = try JSONEncoder().encode(ledger)
        #expect(try JSONDecoder().decode(WatchCommandLedger.self, from: data) == ledger)
    }
}

extension Double {
    func isApproximately(_ other: Double) -> Bool { abs(self - other) < 1e-9 }
}
