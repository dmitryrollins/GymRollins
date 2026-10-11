import SwiftUI

enum AppTab: Hashable { case today, body, library, log }

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .today

    var body: some View {
        if env.onboardingComplete {
            mainTabs
            #if DEBUG
                // During a workout the probe is on the workout flow instead (one probe on screen).
                .overlay(alignment: .top) { if FakeWatchTransport.isEnabled && env.session == nil { FakeWatchProbe() } }
            #endif
        } else {
            OnboardingFlow().preferredColorScheme(.dark)
        }
    }

    private var mainTabs: some View {
        TabView(selection: $tab) {
            Tab("Today", systemImage: "dumbbell", value: .today) { TodayView() }
            Tab("Body", systemImage: "figure.stand", value: .body) { BodyView() }
            Tab("Library", systemImage: "books.vertical", value: .library) { LibraryView() }
            Tab("Log", systemImage: "calendar", value: .log) { LogView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .task {
            await env.sync.start()
            await env.syncHealth() // after the session is restored: the Health import checks who is signed in
        }
        .onChange(of: scenePhase) { _, phase in
            env.sync.setActive(phase == .active)
            if phase == .active { Task { await env.syncHealth() } }
        }
    }
}
