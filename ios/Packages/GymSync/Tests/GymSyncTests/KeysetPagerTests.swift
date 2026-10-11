import Foundation
import Testing
@testable import GymSync

/// An in-memory table ordered by (updated_at, id) that another device can edit between page requests.
private actor PagedTable {
    struct Row: Sendable { let id: String; var updatedAt: Date }
    private(set) var rows: [Row]
    private(set) var requests = 0
    var onPage: (@Sendable (Int) async -> Void)?
    private var clock: Date

    init(rows: [Row], clock: Date) {
        self.rows = rows
        self.clock = clock
    }

    func setOnPage(_ hook: @escaping @Sendable (Int) async -> Void) { onPage = hook }

    /// "Another device" edits a row: it gets a fresh, later updated_at (moves to the end of the ordering).
    func touch(_ id: String) {
        clock = clock.addingTimeInterval(1)
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].updatedAt = clock }
    }

    func page(after: PageKey?, since: Date?, limit: Int) async -> [(row: String, key: PageKey)] {
        let sorted = rows.sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
        let filtered = sorted.filter { row in
            if let after {
                return row.updatedAt > after.updatedAt || (row.updatedAt == after.updatedAt && row.id > after.tiebreak)
            }
            return row.updatedAt > (since ?? .distantPast)
        }
        let page = filtered.prefix(limit).map { (row: $0.id, key: PageKey(updatedAt: $0.updatedAt, tiebreak: $0.id)) }
        requests += 1
        if let onPage { await onPage(requests) }
        return Array(page)
    }
}

@Suite struct KeysetPagerTests {
    private let base = SyncDate.parse("2026-09-27T10:00:00Z")!

    /// 8 rows; five share one updated_at (written by one statement), so the id tiebreak matters.
    private func table() -> PagedTable {
        let shared = base.addingTimeInterval(1)
        let rows = ["a", "b", "c", "d", "e"].map { PagedTable.Row(id: $0, updatedAt: shared) }
            + [PagedTable.Row(id: "f", updatedAt: base.addingTimeInterval(2)),
               PagedTable.Row(id: "g", updatedAt: base.addingTimeInterval(3)),
               PagedTable.Row(id: "h", updatedAt: base.addingTimeInterval(4))]
        return PagedTable(rows: rows, clock: base.addingTimeInterval(100))
    }

    @Test func collectsEveryRowAcrossPagesWithSharedTimestamps() async throws {
        let t = table()
        let rows = try await KeysetPager.collect(pageSize: 3, since: nil) { after, since, limit in
            await t.page(after: after, since: since, limit: limit)
        }
        #expect(rows == ["a", "b", "c", "d", "e", "f", "g", "h"])
        #expect(await t.requests == 3)
    }

    @Test func respectsTheSinceCursor() async throws {
        let t = table()
        let rows = try await KeysetPager.collect(pageSize: 2, since: base.addingTimeInterval(1)) { after, since, limit in
            await t.page(after: after, since: since, limit: limit)
        }
        #expect(rows == ["f", "g", "h"])
    }

    /// With offset paging, a row edited elsewhere between two page requests shifts every later row back by one,
    /// so the next page would skip one. Keyset paging continues after the last row seen and misses nothing.
    @Test func rowMovedBetweenPagesDoesNotHideAnotherRow() async throws {
        let t = table()
        await t.setOnPage { request in if request == 1 { await t.touch("b") } }
        let rows = try await KeysetPager.collect(pageSize: 3, since: nil) { after, since, limit in
            await t.page(after: after, since: since, limit: limit)
        }
        #expect(Set(rows) == Set(["a", "b", "c", "d", "e", "f", "g", "h"]))
        #expect(rows.last == "b") // re-read with its new updated_at, so the cursor lands past the edit
    }

    @Test func emptyTableIsOneRequest() async throws {
        let t = PagedTable(rows: [], clock: base)
        let rows = try await KeysetPager.collect(pageSize: 3, since: nil) { after, since, limit in
            await t.page(after: after, since: since, limit: limit)
        }
        #expect(rows.isEmpty)
        #expect(await t.requests == 1)
    }

    @Test func keyRowDecodesUUIDAndIntTiebreaks() throws {
        let ids = Data("""
        [{"id": "5a2b6c0e-0000-0000-0000-000000000001", "updated_at": "2026-09-27T10:00:00.123456+00:00", "n": 1}]
        """.utf8)
        let keys = try PageKey.decode(ids, tiebreak: "id")
        #expect(keys.first?.tiebreak == "5a2b6c0e-0000-0000-0000-000000000001")
        #expect(keys.first.map { SyncDate.format($0.updatedAt) } == "2026-09-27T10:00:00.123456Z")
        let weekdays = Data(#"[{"weekday": 3, "updated_at": "2026-09-27T10:00:01Z"}]"#.utf8)
        #expect(try PageKey.decode(weekdays, tiebreak: "weekday").first?.tiebreak == "3")
    }
}
