import Foundation

/// A set or plan weight as stored: `kg`, the number every calculation uses, and `lb`, the pound number the weight was
/// entered or chosen as (plan 38). `lb` is nil when nobody gave a pound number (kg entries, imports, old rows); the
/// weight then shows in pounds converted from kg. The two never disagree: an `lb` more than `toleranceKg` away from
/// `kg` is dropped.
public struct PoundWeight: Sendable, Hashable {
    /// How far a pound number's kg may be from the stored kg and still be the same weight.
    public static let toleranceKg = 0.01
    /// How close a listing's kg must come to a whole or quarter pound for the listing to count as made in pounds.
    static let listingToleranceLb = 0.001

    public let kg: Double
    public let lb: Double?

    /// `lb` is kept only when it is a pound number for `kg` (`agreeing`).
    public init(kg: Double, lb: Double?) {
        self.kg = kg
        self.lb = Self.agreeing(lb, kg: kg)
    }

    /// `lb` when it is the pound number of `kg`: both there, finite, and within `toleranceKg` of each other once
    /// converted. Nil otherwise, and for 0 kg: a bodyweight or timed set weighs nothing and has no pound number to keep
    /// (so it never syncs `w_lb: 0`).
    public static func agreeing(_ lb: Double?, kg: Double?) -> Double? {
        guard let lb, let kg, lb.isFinite, kg.isFinite, kg != 0,
              abs(UnitConverter.toKg(lb, from: .lb) - kg) <= toleranceKg else { return nil }
        return lb
    }

    /// The weight a number typed or chosen in `unit` stands for: in pounds the number is its pound number.
    public static func entered(_ value: Double, unit: WeightUnit) -> PoundWeight {
        PoundWeight(kg: UnitConverter.toKg(value, from: unit), lb: unit == .lb ? value : nil)
    }

    /// The nearest ½ lb to `kg`, with that pound number.
    public static func snappedToHalfPound(kg: Double) -> PoundWeight {
        entered((UnitConverter.fromKg(kg, to: .lb) * 2).rounded() / 2, unit: .lb)
    }

    /// `kg` as the new weight of something that weighed `old`: `old` itself, pound number and all, while the kg is the
    /// same; otherwise `kg` with no pound number. For the kg-only setters, so a new kg never keeps a stale pound number.
    public static func replacing(_ old: PoundWeight?, kg: Double) -> PoundWeight {
        old.flatMap { $0.kg == kg ? $0 : nil } ?? PoundWeight(kg: kg, lb: nil)
    }

    /// A weight a gym listing offers. A listing made in pounds stores kg that converts back to a whole or quarter pound,
    /// and that pound number is kept; any other kg has none. The kg stays as listed.
    public static func listing(kg: Double) -> PoundWeight {
        let pounds = UnitConverter.fromKg(kg, to: .lb)
        let quarter = (pounds * 4).rounded() / 4
        return PoundWeight(kg: kg, lb: abs(pounds - quarter) <= listingToleranceLb ? quarter : nil)
    }

    /// This weight carried forward to a new set or plan in `unit`: as it is when it has a pound number or the unit is kg;
    /// in pounds without one, snapped to the nearest ½ lb so an old off-grid value doesn't repeat.
    public func carried(in unit: WeightUnit) -> PoundWeight {
        unit == .lb && lb == nil ? Self.snappedToHalfPound(kg: kg) : self
    }

    /// The number shown in `unit` (`UnitConverter.fromKg(_:lb:to:)`).
    public func value(in unit: WeightUnit) -> Double { UnitConverter.fromKg(kg, lb: lb, to: unit) }
}
