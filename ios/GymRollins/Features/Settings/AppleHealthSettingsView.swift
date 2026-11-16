import GymHealth
import SwiftUI
import UIKit

/// Settings → Apple Health: the opt-in toggle, what is shared, per-type write permission and "Open Settings". Since
/// plan 39 also what is read from Health: workouts from other apps and steps & activity, each with its switch, and the
/// ask for those types when Health was turned on before the app read them.
struct AppleHealthSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var working = false

    private var health: HealthSync { env.health }

    var body: some View {
        Form {
            if health.isAvailable {
                toggleSection
                if health.isEnabled { permissionsSection }
                // Shown with Health off too: what was read before still shows, and these hide it (review M2).
                readingSection
                aboutSection
            } else {
                Section {
                    Text("Apple Health isn't available on this device.")
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("health.unavailable")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task { await health.refreshPermissions() }
    }

    private var toggleSection: some View {
        Section {
            Toggle("Sync with Apple Health", isOn: enabledBinding)
                .disabled(working)
                .accessibilityIdentifier("health.toggle")
            if working { ProgressView().accessibilityIdentifier("health.working") }
            if let error = health.lastError {
                Text(error).font(.footnote).foregroundStyle(Theme.destructive).accessibilityIdentifier("health.error")
            }
        } footer: {
            Text("Saves each finished workout with its estimated calories and the weigh-ins you log here. Reads your "
                 + "weight and body fat into the Body tab, and the workouts other apps record and your daily activity "
                 + "into the Log and Today.")
        }
    }

    private var permissionsSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                Badge(text: HealthStatusText.summary(health.permissions.summary),
                      kind: health.permissions.summary == .allowed ? .success : .record)
                    .accessibilityIdentifier("health.status")
            }
            ForEach(HealthDataType.allCases, id: \.self) { type in
                HStack {
                    Text(type.title)
                    Spacer()
                    Text(HealthStatusText.permission(health.permissions.permission(type)))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("health.permission.\(type.rawValue)")
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .accessibilityIdentifier("health.openSettings")
        } header: {
            Text("Saving to Health")
        } footer: {
            Text("Change these in Settings \u{2192} Health \u{2192} Data Access & Devices \u{2192} GymRollins. Apple "
                 + "Health doesn't tell apps whether they may read, so if your weight doesn't appear, turn on "
                 + "Weight and Body Fat Percentage there.")
        }
    }

    /// What the app reads from Health besides weight (plan 39). Off stops that import and hides it in the app; nothing
    /// already in the cloud is deleted. With Health off nothing new is read, but what was read still shows until its
    /// switch hides it.
    private var readingSection: some View {
        Section {
            if health.needsActivityPermission {
                Button("Allow Reading Your Activity") { allowActivity() }
                    .disabled(working)
                    .accessibilityIdentifier("health.activity.allow")
            }
            Toggle("Workouts from other apps", isOn: Binding(get: { health.state.readsOutsideWorkouts },
                                                            set: { env.setReadsOutsideWorkouts($0) }))
                .accessibilityIdentifier("health.read.workouts")
            Toggle("Steps & activity", isOn: Binding(get: { health.state.readsActivityDays },
                                                    set: { env.setReadsActivityDays($0) }))
                .accessibilityIdentifier("health.read.days")
        } header: {
            Text("Reading from Health")
        } footer: {
            Text("Walks, runs and classes your Apple Watch or other apps record show in the Log and count toward your "
                 + "streak. Steps, move, exercise and stand show on Today. Turning one off hides it here; nothing "
                 + "already in the cloud is deleted."
                 + (health.isEnabled ? "" : " While Apple Health is off nothing new is read, and these still hide "
                    + "what was read before."))
        }
    }

    private var aboutSection: some View {
        Section {
            if let date = health.state.lastImportAt {
                Text("Last read \(date.formatted(.relative(presentation: .named))) \u{00B7} "
                     + "\(health.state.lastImportCount) weigh-in\(health.state.lastImportCount == 1 ? "" : "s") "
                     + "added last time")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("health.lastImport")
            }
            Text("Turning this off stops syncing; what's already in Health stays there.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { health.isEnabled }, set: { on in
            if on {
                working = true
                Task {
                    await health.enable()
                    working = false
                }
            } else {
                health.disable()
            }
        })
    }

    /// Asks Health for the activity types (the sheet lists only those never asked), then reads them.
    private func allowActivity() {
        working = true
        Task {
            await env.allowHealthActivity()
            working = false
        }
    }
}

enum HealthStatusText {
    static func summary(_ summary: HealthPermissions.Summary) -> String {
        switch summary {
        case .allowed: "Connected"
        case .partial: "Partially allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        }
    }

    static func permission(_ permission: HealthPermission) -> String {
        switch permission {
        case .authorized: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet"
        }
    }

    /// The Settings row's badge.
    @MainActor
    static func badge(_ health: HealthSync) -> String {
        guard health.isAvailable else { return "Unavailable" }
        guard health.isEnabled else { return "Off" }
        return summary(health.permissions.summary)
    }
}
