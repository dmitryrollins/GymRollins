import Foundation
import GymData
import Testing
@testable import GymRollins

@Suite struct BodyweightChartDomainTests {
    private func entry(_ kg: Double) -> BodyweightEntry { BodyweightEntry(date: .now, weightKg: kg) }

    @Test func tightAroundTrendAndGoal() {
        let entries = [entry(81.0), entry(81.8)]
        let domain = BodyweightChartDomain.yDomain(entries: entries, goalKg: 85)
        #expect(domain.lowerBound == 80.0)
        #expect(domain.upperBound == 86.0)
    }

    @Test func roundsOutwardToNearestHalf() {
        // min - 1 = 79.7 -> floors to 79.5; max + 1 = 82.9 -> ceils to 83.0.
        let entries = [entry(80.7), entry(81.9)]
        let domain = BodyweightChartDomain.yDomain(entries: entries, goalKg: nil)
        #expect(domain.lowerBound == 79.5)
        #expect(domain.upperBound == 83.0)
    }

    @Test func singleEntryWithoutGoalStillPads() {
        let domain = BodyweightChartDomain.yDomain(entries: [entry(81.0)], goalKg: nil)
        #expect(domain.lowerBound == 80.0)
        #expect(domain.upperBound == 82.0)
    }

    @Test func emptyFallsBackToUnitRange() {
        let domain = BodyweightChartDomain.yDomain(entries: [], goalKg: nil)
        #expect(domain.lowerBound == 0)
        #expect(domain.upperBound == 1)
    }

    @Test func goalFarBelowEntriesStillIncludesGoal() {
        let domain = BodyweightChartDomain.yDomain(entries: [entry(95.0)], goalKg: 85.0)
        #expect(domain.lowerBound == 84.0)
        #expect(domain.upperBound == 96.0)
    }
}
