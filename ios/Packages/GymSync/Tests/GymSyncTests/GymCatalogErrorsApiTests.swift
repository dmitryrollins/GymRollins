import Foundation
import GymData
import Testing
@testable import GymSync

/// `GymCatalogErrors.map` reading the API's errors (spec section 6): the code first, then the status, to the cases the
/// Postgres errors reached, so the app shows the same messages.
@Suite struct GymCatalogErrorsApiTests {
    private func api(_ status: Int, _ code: String, _ message: String = "The server's words.") -> ApiError {
        ApiError(status: status, code: code, message: message)
    }

    @Test func eachRefusalCodeReachesItsCase() {
        let cases: [(ApiError, GymCatalogError)] = [
            (api(422, "daily_limit"), .dailyLimit), (api(422, "gym_not_shareable"), .gymNotShareable),
            (api(422, "photo_missing"), .photoMissing), (api(422, "gym_full"), .gymFull),
            (api(422, "photo_in_use"), .photoInUse), (api(422, "unknown_target"), .unknownTarget),
            (api(422, "place_taken"), .placeTaken), (api(422, "row_rejected"), .noteRefused),
        ]
        for (error, expected) in cases {
            #expect(GymCatalogErrors.map(error, hasSession: true) == expected, "\(error.code)")
        }
    }

    @Test func everyPhotoRuleIsOneRefusal() {
        let codes = ["photo_daily_limit", "photo_name_in_use", "photo_bad_name", "photo_not_jpeg", "photo_owner_missing"]
        for code in codes {
            #expect(GymCatalogErrors.map(api(422, code), hasSession: true) == .photoRefused, "\(code)")
        }
    }

    @Test func theStatusDecidesTheRest() {
        #expect(GymCatalogErrors.map(api(401, "signed_out"), hasSession: true) == .signedOut)
        #expect(GymCatalogErrors.map(api(403, "not_allowed"), hasSession: true) == .notAllowed)
        #expect(GymCatalogErrors.map(api(403, "not_allowed"), hasSession: false) == .signedOut)
        for status in [429, 500, 503] {
            #expect(GymCatalogErrors.map(api(status, "busy"), hasSession: true) == .offline, "\(status)")
        }
        #expect(GymCatalogErrors.map(api(400, "bad_request", "invalid loads"), hasSession: true)
            == .rejected("invalid loads"))
        #expect(GymCatalogErrors.map(api(422, "unknown_listing", "unknown listing"), hasSession: true)
            == .rejected("unknown listing"))
        #expect(GymCatalogErrors.map(api(413, "too_large", "A photo is at most 1 MB."), hasSession: true)
            == .rejected("A photo is at most 1 MB."))
    }

    @Test func aNetworkFailureIsStillOffline() {
        #expect(GymCatalogErrors.map(URLError(.notConnectedToInternet), hasSession: true) == .offline)
    }
}
