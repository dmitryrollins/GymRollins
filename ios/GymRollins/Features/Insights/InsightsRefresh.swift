import SwiftUI
import UIKit

extension View {
    /// Recomputes an insights snapshot when its inputs change and as time passes: recovery keeps improving and a
    /// new week resets the weekly counts even when no data changed. Runs `reload` on appear, on any data/profile
    /// change (`AppEnvironment.insightsRevision`), when the app becomes active, at midnight or a clock/time-zone
    /// change, and every `InsightsRefresh.interval` while visible.
    func insightsRefresh(_ reload: @escaping @MainActor () -> Void) -> some View {
        modifier(InsightsRefresh(reload: reload))
    }
}

struct InsightsRefresh: ViewModifier {
    /// Recovery moves by about 1 % every 30 minutes for a normal session; 10 minutes keeps it current.
    static let interval: Duration = .seconds(600)

    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    let reload: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: env.insightsRevision) {
                reload()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: Self.interval) } catch { return } // cancelled: view went away
                    reload()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in reload() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                reload()
            }
    }
}
