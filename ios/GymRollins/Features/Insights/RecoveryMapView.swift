import GymCore
import SwiftUI

/// Full recovery map: front/back figure, legend and every muscle group with its %; tapping a region or a row opens
/// the group's detail sheet.
struct RecoveryMapView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var snapshot = InsightsSnapshot.empty
    @State private var side: BodySide = .front
    @State private var selected: MuscleGroup?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(snapshot.summaryLine).font(.headline).foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("recovery.summary")
                Picker("Side", selection: $side) {
                    ForEach(BodySide.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("recovery.side")
                BodyMapView(side: side, snapshot: snapshot) { selected = $0 }
                    .frame(maxWidth: .infinity)
                    .frame(height: 480)
                    .accessibilityIdentifier("recovery.map")
                RecoveryLegend(showLimited: !snapshot.limited.isEmpty)
                    .frame(maxWidth: .infinity)
                if !snapshot.limited.isEmpty {
                    Text("Legs are marked limited because of your injury note: \u{201C}\(env.profile.limits)\u{201D}")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("recovery.limitedNote")
                }
                SectionLabel(text: "All muscles")
                groupList
                Text("Recovery estimates how much fatigue your recent hard sets left (warm-ups excluded): about "
                     + "48 h for a normal session, up to 4 days after high volume.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 40)
        }
        .background(Theme.background)
        .navigationTitle("Muscle Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .insightsRefresh { snapshot = env.insights() }
        .sheet(item: $selected) { group in
            MuscleDetailSheet(group: group, snapshot: snapshot)
                .presentationDetents([.medium, .large])
        }
    }

    /// Most fatigued first.
    private var groupList: some View {
        VStack(spacing: 0) {
            ForEach(snapshot.recovery.sorted { ($0.percent, $0.group.displayName) < ($1.percent, $1.group.displayName) }) { r in
                Button { selected = r.group } label: {
                    HStack(spacing: 10) {
                        Circle().fill(RecoveryPalette.fill(r, limited: snapshot.limited.contains(r.group)))
                            .frame(width: 12, height: 12)
                        Text(r.group.displayName).foregroundStyle(Theme.textPrimary)
                        if snapshot.limited.contains(r.group) {
                            Badge(text: "Limited", kind: .neutral)
                        }
                        Spacer()
                        Text("\(r.percent)%").font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(RecoveryPalette.tint(r.status))
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 11)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(snapshot.regionLabel(r.group))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("recovery.row.\(r.group.rawValue)")
                .overlay(alignment: .bottom) { Divider().background(Theme.divider) }
            }
        }
        .padding(.horizontal, 12)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

/// One muscle group: recovery %, status, last trained, when it's fully recovered, and its recent hard sets.
struct MuscleDetailSheet: View {
    let group: MuscleGroup
    let snapshot: InsightsSnapshot
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [MuscleSession] = []

    private var recovery: MuscleRecovery { snapshot.recovery(of: group) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text("\(recovery.percent)%").font(Theme.display(56))
                            .foregroundStyle(RecoveryPalette.tint(recovery.status))
                        Text("recovered \u{00B7} \(RecoveryPalette.label(recovery.status).lowercased())")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(recovery.percent)% recovered, "
                                        + RecoveryPalette.label(recovery.status).lowercased())
                    .accessibilityIdentifier("muscle.header")
                    ProgressView(value: Double(recovery.percent), total: 100)
                        .tint(RecoveryPalette.tint(recovery.status))
                        .accessibilityHidden(true)
                    detailLines
                    SectionLabel(text: "Recent sets")
                    if sessions.isEmpty {
                        Text("No hard sets for \(group.displayName.lowercased()) in the last 4 weeks.")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                            .accessibilityIdentifier("muscle.noSets")
                    } else {
                        ForEach(sessions) { sessionRow($0) }
                    }
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background)
            .navigationTitle(group.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("muscle.done")
                }
            }
        }
        .insightsRefresh { // same triggers as the map, so a sync while the sheet is open updates the sets too
            sessions = MuscleHistory.recent(group: group, workouts: env.recentWorkouts(),
                                            exercise: { env.library.exercise($0) })
        }
    }

    @ViewBuilder
    private var detailLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recovery.lastTrained.map { "Last trained \(Self.day($0))" } ?? "Not trained in the last 4 weeks")
                .accessibilityIdentifier("muscle.lastTrained")
            if let at = recovery.recoveredAt {
                Text("Fully recovered around \(Self.dayTime(at))")
            }
            if snapshot.limited.contains(group) {
                Text("Limited by your injury note: \u{201C}\(env.profile.limits)\u{201D}")
                    .foregroundStyle(Theme.record)
            }
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textSecondary)
    }

    private func sessionRow(_ s: MuscleSession) -> some View {
        let name = DisplayName.of(env.library.exercise(s.exerciseId)?.name ?? s.exerciseId)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                if !s.isPrimary { Badge(text: "Secondary", kind: .neutral) }
                Spacer()
                Text(Self.day(s.date)).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            Text(setsText(s.sets)).font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("muscle.session")
    }

    /// "135 lb × 8, 8, 7" when every set shares the load, else one "load × reps" per set.
    private func setsText(_ sets: [WorkoutSet]) -> String {
        let unit = env.profile.unit
        let describe = { (s: WorkoutSet) -> String in
            if let sec = s.sec, sec > 0, s.reps <= 1 { return "\(sec) s" }
            return "\(s.reps)"
        }
        let loads = Set(sets.map(\.weightKg))
        if loads.count == 1, let kg = loads.first {
            let reps = sets.map(describe).joined(separator: ", ")
            return kg > 0 ? "\(WeightFormatter.format(kg: kg, unit: unit, includeSecondary: false)) \u{00D7} \(reps)"
                : "Bodyweight \u{00D7} \(reps)"
        }
        return sets.map {
            "\(WeightFormatter.format(kg: $0.weightKg, unit: unit, includeSecondary: false)) \u{00D7} \(describe($0))"
        }.joined(separator: ", ")
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private static func dayTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
