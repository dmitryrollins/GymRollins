import Foundation

/// Coalesces bursts of local edits into one sync: every `schedule` restarts the wait, and only the last action
/// runs, `delay` after the last call. `sleep` is injectable so tests don't depend on wall-clock timing.
@MainActor
final class SyncDebouncer {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let delay: Duration
    private let sleep: Sleep
    private var pending: Task<Void, Never>?
    /// The most recently scheduled wait (kept after `cancel`), so tests can await it instead of sleeping.
    private(set) var lastScheduled: Task<Void, Never>?

    init(delay: Duration, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.delay = delay
        self.sleep = sleep
    }

    var isPending: Bool { pending != nil }

    func schedule(_ action: @escaping @MainActor () async -> Void) {
        pending?.cancel()
        let delay = delay, sleep = sleep
        pending = Task { [weak self] in
            do { try await sleep(delay) } catch { return } // cancelled by a newer schedule
            guard !Task.isCancelled else { return }
            self?.pending = nil
            await action()
        }
        lastScheduled = pending
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
