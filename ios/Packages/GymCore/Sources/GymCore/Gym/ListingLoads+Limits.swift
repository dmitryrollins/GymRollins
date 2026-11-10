import Foundation

public extension ListingLoads {
    /// Whether every number is one a listing may hold (`DomainLimits`). Non-finite numbers are never within them. Used
    /// for loads read from the server, which another app version or a bad client may have written.
    var isWithinLimits: Bool {
        switch self {
        case let .stack(maxKg, stepKg):
            guard DomainLimits.listingStackKg.contains(maxKg) else { return false }
            guard let stepKg else { return true }
            return DomainLimits.listingStepKg.contains(stepKg) && stepKg <= maxKg
        case let .fixed(kg):
            return (1...DomainLimits.listingFixedWeightsMax).contains(kg.count)
                && kg.allSatisfy(DomainLimits.listingFixedKg.contains)
        case .plates, .none:
            return true
        }
    }
}

/// The name of a photo in the gym buckets: a UUID and `.jpg`, nothing else. A name from the server that isn't one is
/// not used, because it is put into a URL that carries the user's token.
public enum GymPhotoName {
    public static func isValid(_ name: String) -> Bool {
        name.count == 40 && name.hasSuffix(".jpg") && UUID(uuidString: String(name.dropLast(4))) != nil
    }
}
