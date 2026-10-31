import Foundation
import Testing
@testable import GymCore

@Suite struct ListingLoadsLimitsTests {
    @Test func loadsInsideTheLimitsPass() {
        #expect(ListingLoads.stack(maxKg: 90, stepKg: 5).isWithinLimits)
        #expect(ListingLoads.stack(maxKg: 90, stepKg: nil).isWithinLimits)
        #expect(ListingLoads.fixed(kg: [16, 24]).isWithinLimits)
        #expect(ListingLoads.plates.isWithinLimits)
        #expect(ListingLoads.none.isWithinLimits)
    }

    @Test func loadsOutsideTheLimitsFail() {
        #expect(!ListingLoads.stack(maxKg: 5_000, stepKg: 5).isWithinLimits)
        #expect(!ListingLoads.stack(maxKg: 0, stepKg: nil).isWithinLimits)
        #expect(!ListingLoads.stack(maxKg: 90, stepKg: 0).isWithinLimits)
        #expect(!ListingLoads.stack(maxKg: 10, stepKg: 20).isWithinLimits, "a step above the top weight")
        #expect(!ListingLoads.fixed(kg: []).isWithinLimits)
        #expect(!ListingLoads.fixed(kg: [600]).isWithinLimits)
        #expect(!ListingLoads.fixed(kg: Array(repeating: 10, count: 61)).isWithinLimits)
    }

    @Test func nonFiniteNumbersFail() {
        #expect(!ListingLoads.stack(maxKg: .infinity, stepKg: 5).isWithinLimits)
        #expect(!ListingLoads.stack(maxKg: .nan, stepKg: nil).isWithinLimits)
        #expect(!ListingLoads.stack(maxKg: 90, stepKg: .nan).isWithinLimits)
        #expect(!ListingLoads.fixed(kg: [16, .infinity]).isWithinLimits)
        #expect(!ListingLoads.fixed(kg: [.nan]).isWithinLimits)
    }

    @Test func onlyAUuidAndJpgIsAPhotoName() {
        let id = "3fa85f64-5717-4562-b3fc-2c963f66afa6"
        #expect(GymPhotoName.isValid("\(id).jpg"))
        #expect(GymPhotoName.isValid("\(id.uppercased()).jpg"))
        for bad in ["../\(id).jpg", "\(id).png", "\(id)", "\(id).jpg/../x", "a/\(id).jpg", "", "x.jpg",
                    "\(id).jpg?token=1", "..%2F..%2F\(id).jpg"] {
            #expect(!GymPhotoName.isValid(bad), "\(bad)")
        }
    }
}
