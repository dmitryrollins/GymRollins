import Foundation
import GymData

extension GymCatalogRows {
    /// The rows of an API answer as the row decoders read them, a JSON array: the list under `key`
    /// (`{"rows": [...]}`), or a one-row list for an object answer (`{"gym": {...}}`), empty when it is null.
    static func array(in data: Data, key: String) throws -> Data {
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let value = answer[key]
        else { throw GymCatalogError.rejected("unreadable response") }
        let rows: [Any] = (value as? [Any]) ?? (value is NSNull ? [] : [value])
        return try JSONSerialization.data(withJSONObject: rows)
    }
}
