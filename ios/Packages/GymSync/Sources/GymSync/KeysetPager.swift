import Foundation

/// Position of a row in the pull order `(updated_at, tiebreak)`.
struct PageKey: Sendable, Equatable {
    let updatedAt: Date
    /// The tiebreak column's value as PostgREST should compare it (uuid/text as-is, integers as decimal text).
    let tiebreak: String

    /// Reads each row's `updated_at` and tiebreak column from a PostgREST response (other columns are ignored).
    static func decode(_ data: Data, tiebreak column: String) throws -> [PageKey] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected an array of rows"))
        }
        return try rows.map { row in
            guard let raw = row["updated_at"] as? String, let updatedAt = SyncDate.parse(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Row without updated_at"))
            }
            switch row[column] {
            case let text as String: return PageKey(updatedAt: updatedAt, tiebreak: text)
            case let number as NSNumber: return PageKey(updatedAt: updatedAt, tiebreak: number.stringValue)
            default:
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Row without \(column)"))
            }
        }
    }
}

/// Keyset pagination over `updated_at > since`, ordered by `(updated_at, tiebreak)`: each page asks for rows
/// strictly after the last row of the previous page. Unlike offsets, a row edited elsewhere between two requests
/// can't shift an unseen row out of the next page (the edited row just shows up again at the end).
enum KeysetPager {
    /// `fetch(after, since, limit)` returns up to `limit` rows after `after` (or, for the first page, newer than
    /// `since`), in order, each with its key.
    static func collect<T>(pageSize: Int, since: Date?,
                           fetch: (PageKey?, Date?, Int) async throws -> [(row: T, key: PageKey)]) async throws -> [T] {
        precondition(pageSize > 0, "pageSize must be positive")
        var rows: [T] = []
        var after: PageKey?
        while true {
            let page = try await fetch(after, since, pageSize)
            rows += page.map(\.row)
            guard page.count == pageSize, let last = page.last else { return rows }
            after = last.key
        }
    }
}
