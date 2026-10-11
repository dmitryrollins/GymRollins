public struct PlateInventory: Codable, Sendable, Equatable {
    public let unit: WeightUnit
    /// Bar weight in `unit`.
    public let bar: Double
    /// Plate sizes available per side, in `unit` (unlimited count of each).
    public let plates: [Double]

    public init(unit: WeightUnit, bar: Double, plates: [Double]) {
        self.unit = unit
        self.bar = bar
        self.plates = plates
    }

    public static let standardLb = PlateInventory(unit: .lb, bar: 45, plates: [45, 35, 25, 10, 5, 2.5])
    public static let standardKg = PlateInventory(unit: .kg, bar: 20, plates: [25, 20, 15, 10, 5, 2.5, 1.25])
}

public struct PlateLoad: Sendable, Equatable {
    /// Plates for ONE side, heaviest first, in the inventory unit.
    public let perSide: [Double]
    /// Achieved total (bar + both sides), in the inventory unit.
    public let total: Double
    /// Target minus achieved total (never negative), in the inventory unit.
    public let remainder: Double
}

public enum PlateCalculator {
    /// Above this per-side target (in hundredths of the unit), the exact DP search is skipped
    /// in favor of greedy, to bound worst-case work.
    private static let maxExactPerSideCents = 100_000

    public static func load(targetKg: Double, inventory: PlateInventory) -> PlateLoad {
        let target = toCents(UnitConverter.fromKg(targetKg, to: inventory.unit))
        let bar = toCents(inventory.bar)
        guard target > bar else {
            return PlateLoad(perSide: [], total: inventory.bar, remainder: 0)
        }
        let plates = platesByCents(inventory.plates)
        let perSideTarget = (target - bar) / 2
        let perSideCents = perSideCombination(plates: plates.map(\.cents), target: perSideTarget)
        let perSide = perSideCents.map { plateValue(forCents: $0, in: plates) }
        let usedCents = perSideCents.reduce(0, +)
        let total = bar + 2 * usedCents
        return PlateLoad(perSide: perSide, total: fromCents(total), remainder: fromCents(target - total))
    }

    private static func toCents(_ v: Double) -> Int { Int((v * 100).rounded()) }
    private static func fromCents(_ c: Int) -> Double { Double(c) / 100 }

    private static func platesByCents(_ values: [Double]) -> [(cents: Int, value: Double)] {
        values.map { (toCents($0), $0) }.filter { $0.cents > 0 }.sorted { $0.cents > $1.cents }
    }

    private static func plateValue(forCents cents: Int, in plates: [(cents: Int, value: Double)]) -> Double {
        plates.first { $0.cents == cents }?.value ?? fromCents(cents)
    }

    /// Finds the per-side plate combination (in cents, unlimited count of each) that maximizes
    /// achieved load without exceeding `target`. Falls back to greedy above `maxExactPerSideCents`.
    private static func perSideCombination(plates: [Int], target: Int) -> [Int] {
        guard target > 0, !plates.isEmpty else { return [] }
        guard target <= maxExactPerSideCents else {
            return greedyCombination(plates: plates, target: target)
        }
        return exactCombination(plateCents: plates, target: target)
    }

    private static func greedyCombination(plates: [Int], target: Int) -> [Int] {
        var remaining = target
        var result: [Int] = []
        for plate in plates {
            let count = remaining / plate
            guard count > 0 else { continue }
            result += Array(repeating: plate, count: count)
            remaining -= count * plate
        }
        return result
    }

    /// Unbounded-knapsack search over exact sums (in cents): `minCount[c]` is the fewest plates
    /// needed to hit sum `c` exactly, or `Int.max` if unreachable.
    private static func exactCombination(plateCents: [Int], target: Int) -> [Int] {
        let minCount = minPlateCounts(plateCents: plateCents, target: target)
        guard let bestSum = (0...target).reversed().first(where: { minCount[$0] != Int.max }) else { return [] }
        return reconstruct(plateCents: plateCents, minCount: minCount, sum: bestSum)
    }

    private static func minPlateCounts(plateCents: [Int], target: Int) -> [Int] {
        var minCount = [Int](repeating: Int.max, count: target + 1)
        minCount[0] = 0
        for sum in 1...target {
            var best = Int.max
            for plate in plateCents where plate <= sum && minCount[sum - plate] != Int.max {
                best = min(best, minCount[sum - plate] + 1)
            }
            minCount[sum] = best
        }
        return minCount
    }

    // Tie-break: fewest plates (via minCount), then heaviest plates first (plateCents is sorted descending).
    private static func reconstruct(plateCents: [Int], minCount: [Int], sum: Int) -> [Int] {
        var remaining = sum
        var result: [Int] = []
        while remaining > 0 {
            guard let plate = plateCents.first(where: { candidate in
                candidate <= remaining && minCount[remaining - candidate] == minCount[remaining] - 1
            }) else { break }
            result.append(plate)
            remaining -= plate
        }
        return result
    }
}
