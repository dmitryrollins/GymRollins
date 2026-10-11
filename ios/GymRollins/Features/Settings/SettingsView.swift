import GymCore
import GymData
import SwiftUI

/// The app's single Settings screen (mockup `Settings.dc.html`): account/sync (folded from `AccountSection`),
/// training preferences, Claude, import/export, privacy and about. Reached from the Log tab's gear and Today's
/// avatar.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var unit: WeightUnit = .lb
    @AppStorage(WarmupPreferences.autoWarmupsKey) private var autoWarmups = true
    @AppStorage(ProgressionDefaultPreference.key) private var progressionRaw = ProgressionPolicy.double.rawValue
    @State private var showBarAndPlates = false
    @State private var showImport = false
    @State private var showPrivacy = false
    @State private var showCredits = false
    @State private var confirmDelete = false
    @State private var showDeleteSheet = false
    @State private var exportError: String?
    @State private var sharing: ExportShare?
    @State private var claudeLastUse: Date?
    @State private var claudeChecked = false

    private var isSignedIn: Bool {
        if case .signedIn = env.sync.authState { return true }
        return false
    }

    private var claudeBadge: ClaudeConnectionBadge {
        ClaudeConnectionBadge.make(signedIn: isSignedIn, checked: claudeChecked, lastUse: claudeLastUse)
    }

    var body: some View {
        Form {
            Section("Account") { AccountSection() }
            trainingSection
            claudeSection
            healthSection
            dataSection
            privacySection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .tint(Theme.accent)
        .task { unit = env.profile.unit }
        .task(id: isSignedIn) { await loadClaudeLastUse() }
        .sheet(item: $sharing, onDismiss: ExportService.removeExportFiles) { share in
            ExportShareSheet(url: share.url) { sharing = nil }
                .presentationDetents([.medium, .large])
        }
        .navigationDestination(isPresented: $showBarAndPlates) { BarAndPlatesView() }
        .navigationDestination(isPresented: $showImport) {
            ImportCSVView(onBack: { showImport = false }, onDone: { showImport = false })
        }
        .navigationDestination(isPresented: $showPrivacy) { PrivacyPolicyView() }
        .navigationDestination(isPresented: $showCredits) { CreditsView() }
        .confirmationDialog("Delete your account and all its data? This can't be undone.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Continue", role: .destructive) { showDeleteSheet = true }
                .accessibilityIdentifier("settings.delete.continue")
        }
        .sheet(isPresented: $showDeleteSheet) {
            if isSignedIn {
                DeleteAccountSheet(identifierPrefix: "settings.delete") { runDelete { try await env.sync.deleteAccount() } }
            } else {
                DeleteAccountSheet(message: "Every workout, plan, weigh-in and custom exercise on this iPhone will "
                                    + "be erased. This can't be undone.", confirmTitle: "Erase All Data",
                                   navigationTitle: "Erase Data", identifierPrefix: "settings.delete") {
                    runDelete { try env.eraseAllLocalData() }
                }
            }
        }
    }

    // MARK: Training

    private var trainingSection: some View {
        Section("Training") {
            Picker("Units", selection: $unit) {
                Text("lb plates").tag(WeightUnit.lb)
                Text("kg plates").tag(WeightUnit.kg)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.units")
            .onChange(of: unit) { _, new in changeUnit(to: new) }

            NavigationLink { RestDefaultsView() } label: {
                HStack {
                    Text("Default rest")
                    Spacer()
                    Text(DurationFormatter.clock(TimeInterval(env.profile.restSec)))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityIdentifier("settings.rest")

            Button { showBarAndPlates = true } label: {
                HStack {
                    Text("Bar & plates inventory").foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
                }
            }
            .accessibilityIdentifier("settings.barPlates")

            NavigationLink { WeeklyTargetsView() } label: { Text("Weekly targets") }
                .accessibilityIdentifier("settings.weeklyTargets")

            Toggle("Warm-up sets", isOn: $autoWarmups).accessibilityIdentifier("settings.autoWarmups")

            Picker("Progression default", selection: $progressionRaw) {
                ForEach(ProgressionPolicy.allCases, id: \.rawValue) { policy in
                    Text(policy.rawValue.capitalized).tag(policy.rawValue)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.progression")

            deloadRow

            NavigationLink { HiddenExercisesView() } label: {
                HStack {
                    Text("Hidden exercises")
                    Spacer()
                    Text("\(env.hiddenExercises().count)").foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityIdentifier("settings.hiddenExercises")
        }
    }

    private var deloadRow: some View {
        Stepper(value: deloadBinding, in: 2.5...10, step: 2.5) {
            HStack {
                Text("Deload")
                Spacer()
                Text("\(WeightFormatter.number(env.profile.deloadPct * 100))%").foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityIdentifier("settings.deload")
    }

    private var deloadBinding: Binding<Double> {
        Binding(get: { env.profile.deloadPct * 100 }, set: { save(env.profile.with(deloadPct: $0 / 100)) })
    }

    // MARK: Claude

    private var claudeSection: some View {
        Section("Claude") {
            NavigationLink { ClaudeConnectionView() } label: {
                HStack {
                    Text("Claude connection")
                    Spacer()
                    Badge(text: claudeBadge.text, kind: claudeBadge.kind)
                        .accessibilityIdentifier("settings.claude.badge")
                }
            }
            .accessibilityIdentifier("settings.claude")
        }
    }

    // MARK: Apple Health

    private var healthSection: some View {
        Section("Apple Health") {
            NavigationLink { AppleHealthSettingsView() } label: {
                HStack {
                    Text("Apple Health")
                    Spacer()
                    Badge(text: HealthStatusText.badge(env.health), kind: env.health.isEnabled ? .success : .neutral)
                        .accessibilityIdentifier("settings.health.badge")
                }
            }
            .accessibilityIdentifier("settings.health")
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section("Data") {
            Button { showImport = true } label: {
                HStack {
                    Text("Import CSV").foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
                }
            }
            .accessibilityIdentifier("settings.importCSV")

            exportRow(title: "Export all data (JSON)", identifier: "settings.exportJSON") {
                try env.exportService().writeBackupFile()
            }
            exportRow(title: "Export CSV (Fitbod format)", identifier: "settings.exportCSV") {
                try env.exportService().writeWorkoutsCSVFile()
            }
            if let exportError {
                Text(exportError).foregroundStyle(Theme.destructive).accessibilityIdentifier("settings.export.error")
            }
        }
    }

    /// Builds the file from current data on every tap (never a cached one), then shares it; the file is deleted
    /// when the share sheet closes.
    private func exportRow(title: String, identifier: String, build: @escaping () throws -> URL) -> some View {
        Button(title) {
            do {
                sharing = ExportShare(url: try build())
                exportError = nil
            } catch {
                AppEnvironment.log.error("Export failed: \(error.localizedDescription, privacy: .public)")
                exportError = "Couldn't prepare the export. Please try again."
            }
        }
        .accessibilityIdentifier(identifier)
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section("Privacy") {
            Button { showPrivacy = true } label: {
                HStack {
                    Text("Privacy policy").foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
                }
            }
            .accessibilityIdentifier("settings.privacyPolicy")

            Button(isSignedIn ? "Delete Account and Data" : "Erase All Data on This iPhone", role: .destructive) {
                confirmDelete = true
            }
            .accessibilityIdentifier("settings.delete")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Self.versionString).foregroundStyle(Theme.textSecondary)
            }
            Button { showCredits = true } label: {
                HStack {
                    Text("Exercise data & photo credits").foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
                }
            }
            .accessibilityIdentifier("settings.credits")
            Button { showCredits = true } label: {
                HStack {
                    Text("Open-source notices").foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
                }
            }
            .accessibilityIdentifier("settings.openSource")
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: Actions

    /// Units switch: storage stays kg, but the plate inventory (bar + plates, and `barKg`) maps to the new unit's standard
    /// set, since a lb inventory's sizes (45/35/25…) don't correspond to sensible kg plates. Any custom plate
    /// selection made in Bar & Plates is lost on a switch — noted so it isn't a silent surprise.
    private func changeUnit(to new: WeightUnit) {
        guard new != env.profile.unit else { return }
        save(env.profile.withStandardEquipment(for: new))
    }

    /// Once per appearance (and sign-in change): whether Claude has used the MCP server for this account.
    /// Signed out there is no connector to ask about, so no network call.
    private func loadClaudeLastUse() async {
        guard isSignedIn else {
            claudeLastUse = nil
            claudeChecked = true
            return
        }
        claudeChecked = false
        claudeLastUse = await env.sync.lastMcpUse()
        claudeChecked = true
    }

    private func save(_ profile: Profile) {
        do {
            try env.profiles.save(profile)
            env.reloadProfile()
            env.planChanged()
        } catch {
            AppEnvironment.log.error("Save settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runDelete(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch {
                AppEnvironment.log.error("Delete/erase failed: \(error.localizedDescription, privacy: .public)")
                exportError = "Something went wrong. Please try again."
            }
        }
    }
}

/// Working / warm-up rest, in seconds, validated against `DomainLimits.restSec` (0…900).
private struct RestDefaultsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var restSec = 120
    @State private var warmupRestSec = 60
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Stepper("Working rest: \(DurationFormatter.clock(TimeInterval(restSec)))", value: $restSec,
                       in: DomainLimits.restSec, step: 15)
                    .accessibilityIdentifier("settings.rest.working")
                Stepper("Warm-up rest: \(DurationFormatter.clock(TimeInterval(warmupRestSec)))",
                       value: $warmupRestSec, in: DomainLimits.restSec, step: 15)
                    .accessibilityIdentifier("settings.rest.warmup")
            }
            if let error { Text(error).foregroundStyle(Theme.destructive) }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Default Rest")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task {
            restSec = env.profile.restSec
            warmupRestSec = env.profile.warmupRestSec
        }
        .onChange(of: restSec) { _, _ in save() }
        .onChange(of: warmupRestSec) { _, _ in save() }
    }

    private func save() {
        let updated = env.profile.with(restSec: restSec, warmupRestSec: warmupRestSec)
        do {
            try env.profiles.save(updated)
            env.reloadProfile()
            env.planChanged()
            error = nil
        } catch {
            AppEnvironment.log.error("Save rest defaults failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save. Please try again."
        }
    }
}
