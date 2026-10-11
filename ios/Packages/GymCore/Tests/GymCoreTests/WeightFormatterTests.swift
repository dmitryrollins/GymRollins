import Testing
@testable import GymCore

@Suite struct WeightFormatterTests {
    @Test func convertsBothWays() {
        #expect(abs(UnitConverter.toKg(140, from: .lb) - 63.5029318) < 0.0001)
        #expect(abs(UnitConverter.fromKg(63.5029318, to: .lb) - 140) < 0.0001)
        #expect(UnitConverter.toKg(20, from: .kg) == 20)
    }

    @Test func formatsPrimaryAndSecondary() {
        #expect(WeightFormatter.format(kg: 63.5029318, unit: .lb) == "140 lb (63.5 kg)")
        #expect(WeightFormatter.format(kg: 20, unit: .kg) == "20 kg (44.1 lb)")
        #expect(WeightFormatter.format(kg: 12.4737954, unit: .lb) == "27.5 lb (12.5 kg)")
    }

    @Test func formatsPrimaryOnly() {
        #expect(WeightFormatter.format(kg: 63.5029318, unit: .lb, includeSecondary: false) == "140 lb")
    }

    @Test func numberTrimsTrailingZero() {
        #expect(WeightFormatter.number(81.0) == "81")
        #expect(WeightFormatter.number(81.04) == "81")
        #expect(WeightFormatter.number(81.06) == "81.1")
    }
}
