import GymCore
import SwiftUI

struct LibraryView: View {
    /// Presenting `CustomExerciseView` and its prefilled name as one state value (rather than two separate
    /// `@State` flags) makes the sheet's initial name atomic with presentation — no risk of the sheet's content
    /// closure ever building before the name is set.
    private struct CreateRequest: Identifiable { let id = UUID(); let name: String }

    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var bodyPart: String?
    @State private var createRequest: CreateRequest?

    private var results: [Exercise] {
        env.library.search(query: query, bodyPart: bodyPart)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Lazy stack: the library has 1000+ entries, so rows must only be realized near
                // the visible viewport. UI tests that need a deep row search/filter it into view
                // (or scroll for it) instead of relying on it being eagerly present off-screen.
                LazyVStack(alignment: .leading, spacing: 8) {
                    filterBar
                    if results.isEmpty && !query.isEmpty {
                        emptyState
                    } else {
                        Text("\(results.count) exercises")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(results) { ex in
                        NavigationLink(value: ex.id) {
                            ExerciseRow(exercise: ex, fallbackName: ex.name,
                                        subtitle: "\(DisplayName.of(ex.bodyPart)) \u{00B7} \(DisplayName.of(ex.equipment))",
                                        badge: ex.isCustom ? Badge(text: "Custom", kind: .neutral) : nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("library.row.\(ex.id)")
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 100)
            }
            .background(Theme.background)
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Search exercises")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { createRequest = CreateRequest(name: "") } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New exercise")
                        .accessibilityIdentifier("library.add")
                }
            }
            .navigationDestination(for: String.self) { id in ExerciseDetailView(exerciseId: id) }
            .sheet(item: $createRequest) { request in CustomExerciseView(prefillName: request.name) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No exercises match '\(query)'")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("library.empty.title")
            SecondaryGlassButton(title: "Create '\(query)' as a Custom Exercise", identifier: "library.empty.create") {
                createRequest = CreateRequest(name: query)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(title: "All", id: "all", selected: bodyPart == nil) { bodyPart = nil }
                    ForEach(env.library.bodyParts, id: \.self) { part in
                        chip(title: DisplayName.of(part), id: part, selected: bodyPart == part) { bodyPart = part }
                    }
                }
            }
        }
    }

    private func chip(title: String, id: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .bold : .semibold))
                .foregroundStyle(selected ? Theme.background : Theme.textPrimary)
        }
        .buttonStyle(HitAreaButtonStyle())
        .glassCapsule(tint: selected ? Theme.textPrimary : nil)
        .accessibilityIdentifier("library.filter.\(id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
