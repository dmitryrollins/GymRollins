import GymCore
import SwiftUI

struct ExerciseDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let exerciseId: String
    @State private var tab = 0
    @State private var confirmingNever: String?
    @State private var error: String?

    var body: some View {
        if let ex = env.library.exercise(exerciseId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 3:2 like the upstream photos, so the card doesn't jump when a photo replaces the icon.
                    ExercisePhotoView(exercise: ex, iconSize: 120, showsCredit: true)
                        .aspectRatio(3 / 2, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Theme.card)
                        .clipShape(.rect(cornerRadius: 24))
                    Text(DisplayName.of(ex.name)).font(Theme.display(34))
                        .accessibilityIdentifier("detail.title")
                    if let error { Text(error).foregroundStyle(Theme.destructive) }
                    Picker("Section", selection: $tab) {
                        Text("Instructions").tag(0)
                        Text("Muscles").tag(1)
                        Text("Equipment").tag(2)
                    }
                    .pickerStyle(.segmented)
                    content(ex)
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: ExerciseWebSearch.url(for: DisplayName.of(ex.name))) {
                        Image(systemName: "globe")
                    }
                    .accessibilityLabel("Search the web for how to do \(DisplayName.of(ex.name))")
                    .accessibilityIdentifier("exercise.webSearch")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ExercisePreferenceMenuItems(exerciseId: exerciseId, confirmingNever: $confirmingNever,
                                                    error: $error)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More for \(DisplayName.of(ex.name))")
                    .accessibilityIdentifier("exercise.menu")
                }
            }
            .exercisePreferenceConfirmation($confirmingNever, error: $error)
        } else {
            ContentUnavailableView("Exercise not found", systemImage: "questionmark")
        }
    }

    @ViewBuilder
    private func content(_ ex: Exercise) -> some View {
        switch tab {
        case 0:
            SectionLabel(text: "Instructions")
            if ex.instructions.isEmpty {
                Text("No instructions for this exercise yet.").foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(ex.instructions.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)").font(Theme.display(22)).foregroundStyle(Theme.accent)
                    Text(step).foregroundStyle(Theme.textPrimary)
                }
            }
            if let names = env.otherNames?.entry(for: ex.id) {
                OtherNamesCard(entry: names)
            }
        case 1:
            SolidCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target: \(DisplayName.of(ex.target))").font(.headline)
                    if !ex.secondary.isEmpty {
                        Text("Secondary: \(ex.secondary.map(DisplayName.of).joined(separator: ", "))")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        default:
            SolidCard { Text(DisplayName.of(ex.equipment)).font(.headline) }
        }
    }
}

/// The exercise's names in other languages (wger, per-name CC licenses) with their credit. Search and import
/// matching accept these names; the app keeps showing the English one.
struct OtherNamesCard: View {
    let entry: ExerciseNamesI18n.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Other names")
                .accessibilityIdentifier("detail.otherNames")
            SolidCard {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entry.languages, id: \.code) { language in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(language.displayName)
                                .font(.footnote).foregroundStyle(Theme.textSecondary)
                                .frame(minWidth: 72, alignment: .leading)
                            Text(language.names.map(\.text).joined(separator: ", "))
                                .font(.subheadline).foregroundStyle(Theme.textPrimary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            credit
        }
        .padding(.top, 8)
    }

    private var credit: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Names from wger.de by \(entry.authors.joined(separator: ", ")) \u{00B7} "
                 + entry.licenses.joined(separator: ", "))
                .font(.caption).foregroundStyle(Theme.textTertiary)
            ForEach(entry.sources, id: \.self) { url in
                Link(url.host().map { "\($0)\(url.path())" } ?? url.absoluteString, destination: url)
                    .font(.caption)
            }
        }
        .accessibilityIdentifier("detail.otherNames.credit")
    }
}

/// A Google search for how to do an exercise, opened in the browser from the exercise's detail screen.
enum ExerciseWebSearch {
    static func url(for exerciseName: String) -> URL {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: "how to do \(exerciseName)")]
        return components.url!
    }
}
