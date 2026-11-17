import Foundation
import GymData
import Testing
@testable import GymSync

/// Plan 39: "Read activity from Apple Health" travels as `mcp_read_activity`, a JSON boolean like the other switches. A
/// row from before the column existed reads as on, its default.
@Suite struct ProfileReadActivityDTOTests {
    @Test func theSwitchRoundTripsAndAnOldRowReadsAsOn() throws {
        var p = ProfileSnapshot()
        #expect(p.mcpReadActivity)
        p.mcpReadActivity = false
        let row = SyncRow(value: p, clientUpdatedAt: t0)
        let body = try SyncJSON.encoder.encode(ProfileDTO(row))
        #expect(String(decoding: body, as: UTF8.self).contains(#""mcp_read_activity":false"#))
        #expect(try !wire(ProfileDTO(row)).toDomain().value.mcpReadActivity)

        var json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        json.removeValue(forKey: "mcp_read_activity")
        let old = try SyncJSON.decoder.decode(ProfileDTO.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.mcpReadActivity)
        #expect(old.toDomain().value.mcpReadActivity)
    }
}
