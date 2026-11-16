import Foundation

/// Ids looked up together with `#Predicate { ids.contains($0.id) }`, `size` at a time: each `IN (…)` the store builds
/// stays well under SQLite's limit on bound parameters, however many ids a Health import brings.
enum IdBatches {
    static let size = 500

    /// The distinct ids, in batches of at most `size`.
    static func of(_ ids: some Sequence<UUID>) -> [[UUID]] {
        let distinct = Array(Set(ids))
        return stride(from: 0, to: distinct.count, by: size).map {
            Array(distinct[$0..<min($0 + size, distinct.count)])
        }
    }
}
