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
    @State private var showSettings = false
    /// The header shows the search field in place of its pill (owner, 2026-11-19: search behind a button in the
    /// header, as in a contacts app).
    @State private var searching = false

    var body: some View {
        // Searched once per body pass: the empty state, the header's count and the rows all read it.
        let results = env.library.search(query: query, bodyPart: bodyPart)
        NavigationStack {
            ScrollView {
                // Lazy stack: the library has 1000+ entries, so rows must only be realized near
                // the visible viewport. UI tests that need a deep row search/filter it into view
                // (or scroll for it) instead of relying on it being eagerly present off-screen.
                LazyVStack(alignment: .leading, spacing: 8) {
                    filterBar
                    if results.isEmpty && !query.isEmpty { emptyState }
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
            .scrollDismissesKeyboard(.immediately)
            .fixedHeader { header(count: results.count) }
            .background(Theme.background)
            .navigationDestination(for: String.self) { id in ExerciseDetailView(exerciseId: id) }
            .navigationDestination(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $createRequest) { request in CustomExerciseView(prefillName: request.name) }
        }
    }

    /// Settings, then the pill with the count of exercises shown (it follows the body-part filter and the search),
    /// then Search and New exercise. Searching, the field takes the pill's place and ✕ closes it.
    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            SettingsCircle(identifier: "library.settings") { showSettings = true }
            if searching {
                SearchField(prompt: "Search exercises", text: $query, identifier: "library.search", focusOnAppear: true)
                HeaderButtons {
                    Button { closeSearch() } label: { HeaderIcon(systemName: "xmark") }
                        .accessibilityLabel("Close search")
                        .accessibilityIdentifier("library.closeSearch")
                }
            } else {
                HeaderPill(title: "Library",
                           subtitle: count == 1 ? "1 exercise" : "\(count.formatted()) exercises", prefix: "library")
                HeaderButtons {
                    Button { withAnimation(.snappy) { searching = true } } label: {
                        HeaderIcon(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search exercises")
                    .accessibilityIdentifier("library.searchButton")
                    Button { createRequest = CreateRequest(name: "") } label: { HeaderIcon(systemName: "plus") }
                        .accessibilityLabel("New exercise")
                        .accessibilityIdentifier("library.add")
                }
            }
        }
    }

    /// Back to the whole library (under the body-part filter).
    private func closeSearch() {
        withAnimation(.snappy) {
            query = ""
            searching = false
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
