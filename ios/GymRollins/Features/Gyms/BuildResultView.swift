import GymCore
import GymData
import SwiftUI

/// The built workout (spec §6): title, banners, a row per exercise with the photo of the item it uses, Rebuild and
/// Start. "+ Add equipment" builds again with the same request when something was added.
struct BuildResultView: View {
    @Environment(AppEnvironment.self) private var env
    let run: BuildRun
    let gym: Gym
    let muscles: [BuildMuscle]
    let length: BuildLength
    let onStart: (_ name: String, _ items: [RoutineExercise]) -> Void
    @State private var model: BuildResultModel?
    @State private var showAdd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let model { content(model) } else { failure }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("build.result")
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { if let model, !model.isEmpty { actions(model) } }
        .sheet(isPresented: $showAdd) {
            AddEquipmentFlow(gym: gym) { outcome in
                if case .created = outcome { run.rebuildAfterAddingEquipment() }
            }
        }
        .task(id: run.built) { refresh() }
    }

    // MARK: Parts

    private func content(_ model: BuildResultModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                DisplayTitle(text: model.title, size: 34).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("build.title")
                Text(model.subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("build.subtitle")
            }
            if model.isEmpty { Text("Nothing fits yet").font(.title3.weight(.bold)).accessibilityIdentifier("build.empty") }
            ForEach(model.thinNotices, id: \.self) { notice($0, identifier: "build.thin", amber: true) }
            if model.offersAddEquipment {
                SecondaryGlassButton(title: "+ Add equipment", identifier: "build.addEquipment") { showAdd = true }
            }
            if let skipped = model.skippedNotice { notice(skipped, identifier: "build.skipped", amber: false) }
            if let short = model.shortNotice { notice(short, identifier: "build.short", amber: false) }
            ForEach(model.rows) { row($0) }
        }
    }

    private var failure: some View {
        Text("Couldn't build a workout. Go back and try again.")
            .foregroundStyle(Theme.destructive).accessibilityIdentifier("build.error")
    }

    private func notice(_ text: String, identifier: String, amber: Bool) -> some View {
        Text(text).font(.subheadline.weight(.semibold))
            .foregroundStyle(amber ? Theme.record : Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(amber ? Theme.record.opacity(0.3) : .clear))
            .accessibilityIdentifier(identifier)
    }

    private func row(_ row: BuildResultModel.Row) -> some View {
        ExerciseRow(exercise: env.library.exercise(row.exerciseId), fallbackName: row.name, subtitle: row.subtitle,
                    badge: row.mark.map { Badge(text: $0.text, kind: $0 == .repeated ? .record : .neutral) },
                    note: row.note, photoFile: row.photoFile)
            .accessibilityIdentifier("build.row.\(row.exerciseId)")
    }

    private func actions(_ model: BuildResultModel) -> some View {
        let rebuild = SecondaryGlassButton(title: "Rebuild", identifier: "build.rebuild", minHeight: 56) { run.rebuild() }
        let start = PrimaryGlassButton(title: "Start", identifier: "build.start") {
            if let items = run.built?.items.map(\.exercise) { onStart(model.title, items) }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { rebuild; start }
            VStack(spacing: 8) { start; rebuild }
        }
        .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
    }

    // MARK: Loading

    private func refresh() {
        guard let built = run.built else {
            model = nil
            return
        }
        model = BuildResultModel.make(built: built, muscles: muscles, length: length, gymName: gym.name,
                                      gym: env.todayGymContext(), profile: env.profile, library: env.library,
                                      history: history)
    }

    private func history(_ exerciseId: String) -> [SessionResult] {
        do { return try env.workouts.history(exerciseId: exerciseId, limit: 5) }
        catch {
            AppEnvironment.log.error("Read history for Build failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
