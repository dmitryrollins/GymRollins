import GymSync
import Observation
import SwiftUI

/// One account deletion (or erase) in progress. The sheet has closed by the time it runs, and the photo step can take a
/// while: the Settings row shows that something is happening and can't be tapped again. A refusal says what happened,
/// including whether the photos are already gone, next to the row; a retry clears it.
@MainActor
@Observable
final class DeletionRun {
    private(set) var progress: String?
    private(set) var error: String?

    func run(progress text: String, _ action: @escaping () async throws -> Void) {
        guard progress == nil else { return }
        progress = text
        error = nil
        Task {
            do { try await action() } catch {
                AppEnvironment.log.error("Delete/erase failed: \(error.localizedDescription, privacy: .public)")
                self.error = (error as? AuthFailure)?.message ?? "Something went wrong. Please try again."
            }
            progress = nil
        }
    }
}

struct DeletionStatusRows: View {
    let run: DeletionRun

    var body: some View {
        if let progress = run.progress {
            HStack(spacing: 8) {
                ProgressView()
                Text(progress).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.delete.progress")
        }
        if let error = run.error {
            Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("settings.delete.error")
        }
    }
}
