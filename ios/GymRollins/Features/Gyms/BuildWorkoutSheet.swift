import GymCore
import GymData
import SwiftUI

/// Build workout (spec §6): six muscle chips, a length and Build. The result is pushed on this sheet's own stack; its
/// Start hands the built list to the caller, which closes the sheet and starts the workout.
struct BuildWorkoutSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let gym: Gym
    let onStart: (BuiltStart) -> Void
    @State private var setup = BuildSetup()
    @State private var itemCount = 0
    @State private var pushed: PushedBuild?

    /// The request behind the pushed result, and its run (carried here so the destination never sees a stale one).
    private struct PushedBuild: Hashable {
        let id = UUID()
        let muscles: [BuildMuscle]
        let length: BuildLength
        let run: BuildRun

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DisplayTitle(text: "Build workout", size: 34).accessibilityAddTraits(.isHeader)
                    Text("at \(gym.name) \u{00B7} \(itemCount == 1 ? "1 item" : "\(itemCount) items")")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("build.gymLine")
                    SectionLabel(text: "Muscles")
                    chips
                    SectionLabel(text: "Length")
                    lengths
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 24)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("build.sheet")
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) {
                PrimaryGlassButton(title: "Build", identifier: "build.go") { build() }
                    .disabled(setup.muscles.isEmpty)
                    .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("build.close")
                }
            }
            .navigationDestination(item: $pushed) { request in
                BuildResultView(run: request.run, gym: gym, muscles: request.muscles, length: request.length,
                                onStart: onStart)
            }
        }
        .presentationDetents([.large])
        .task {
            setup = BuildSetup.load(from: env.defaults)
            do { itemCount = try env.gyms.itemCounts()[gym.id] ?? 0 }
            catch { AppEnvironment.log.error("Read item count failed: \(error.localizedDescription, privacy: .public)") }
        }
        .onChange(of: setup) { _, new in new.save(to: env.defaults) }
    }

    private var chips: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(BuildMuscle.allCases) { muscle in
                let selected = setup.muscles.contains(muscle)
                choice(muscle.title, selected: selected, minHeight: 72, font: .title3.weight(.semibold),
                       identifier: "build.chip.\(muscle.rawValue)") { setup = setup.toggling(muscle) }
            }
        }
    }

    private var lengths: some View {
        HStack(spacing: 10) {
            ForEach(BuildLength.allCases, id: \.rawValue) { length in
                choice("\(length.rawValue) min", selected: setup.length == length, minHeight: Theme.minTapSize + 12,
                       font: .headline, identifier: "build.length.\(length.rawValue)") { setup = setup.with(length: length) }
            }
        }
    }

    /// A large solid button that shows whether it's chosen with a fill, a check mark and the selected trait.
    private func choice(_ title: String, selected: Bool, minHeight: CGFloat, font: Font, identifier: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.footnote.weight(.bold)) }
                Text(title).font(font).multilineTextAlignment(.center)
            }
            .foregroundStyle(selected ? Color.white : Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(selected ? Theme.primaryFill : Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(selected ? .clear : Theme.textTertiary, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func build() {
        let muscles = setup.muscles, length = setup.length
        let new = BuildRun { [env] avoid in env.buildWorkout(muscles: muscles, length: length, avoid: avoid) }
        new.build()
        pushed = PushedBuild(muscles: muscles, length: length, run: new)
    }
}
