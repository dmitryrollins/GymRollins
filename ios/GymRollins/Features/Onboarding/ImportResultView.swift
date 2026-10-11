import GymCore
import GymData
import SwiftUI

/// After building an `ImportPlan`: resolve any unmatched exercise names (library search or "create as custom"),
/// then run the actual import (batched, with progress) and show the success summary.
struct ImportResultView: View {
    @Environment(AppEnvironment.self) private var env
    let plan: ImportPlan
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var choices: [String: ImportPlan.Resolution] = [:]
    @State private var importing = false
    @State private var progress: Double = 0
    @State private var summary: ImportSummary?
    @State private var error: String?
    @State private var showPicker = false
    /// Non-nil while the match-options sheet for this name is up. A single optional (rather than a separate
    /// `Bool` + name pair) so presenting it for a *different* row can't leave the two out of sync.
    @State private var dialogName: String?
    /// The name the library picker sheet is resolving (kept separate from `dialogName`, which is cleared before
    /// the picker sheet opens so the two sheets never try to show at once).
    @State private var searchingName: String?

    private var unresolved: [String] { plan.needsChoice.filter { choices[$0] == nil } }
    private var allResolved: Bool { unresolved.isEmpty }
    private var matchedCount: Int { plan.names.count - plan.needsChoice.count }

    private var dialogPresented: Binding<Bool> {
        Binding(get: { dialogName != nil }, set: { if !$0 { dialogName = nil } })
    }

    private func suggestionExercise(for name: String) -> Exercise? {
        guard case .needsChoice(let suggestion) = plan.resolved(name), let suggestion else { return nil }
        return env.library.exercise(suggestion)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if summary == nil { OnboardingBackButton(action: onBack) }
                if let summary {
                    successHeader(summary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(text: "Import")
                        DisplayTitle(text: allResolved ? "Ready to import" : "Match your exercises", size: 30)
                    }
                }
                VStack(spacing: 10) {
                    matchedRow
                    if !plan.stats.rowErrors.isEmpty { SkippedRowsCard(errors: plan.stats.rowErrors) }
                    if !plan.needsChoice.isEmpty { needsChoiceCard }
                    warmupRow
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.destructive).accessibilityIdentifier("result.error")
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 58)
            .padding(.bottom, 110)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if importing { ProgressView(value: progress).tint(Theme.accent) }
                PrimaryGlassButton(title: summary == nil ? "Import" : "Continue", identifier: "result.continue") {
                    primaryAction()
                }
                .disabled(!allResolved || importing)
            }
            .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
        }
        .sheet(isPresented: dialogPresented) {
            if let name = dialogName {
                MatchOptionsSheet(name: name, suggestion: suggestionExercise(for: name),
                                  onUseSuggestion: { id in choices[name] = .library(id) },
                                  onSearch: { dialogName = nil; searchingName = name; showPicker = true },
                                  onCustom: { choices[name] = .custom })
            }
        }
        .sheet(isPresented: $showPicker) {
            ExercisePickerView(excluded: [], singleSelect: true, hidesNever: false) { ids in
                if let id = ids.first, let name = searchingName { choices[name] = .library(id) }
            }
        }
    }

    private func successHeader(_ summary: ImportSummary) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.successFill).frame(width: 76, height: 76)
                Image(systemName: "checkmark").font(.system(size: 32, weight: .bold)).foregroundStyle(Theme.success)
            }
            DisplayTitle(text: "Import complete", size: 30)
            Text(statsLine(summary)).font(.footnote).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("result.success")
    }

    private func statsLine(_ summary: ImportSummary) -> String {
        var parts = ["\(summary.workouts) workouts", "\(summary.sets) sets"]
        if !summary.rowErrors.isEmpty { parts.append(SkippedRowsCard.title(count: summary.rowErrors.count)) }
        if summary.duplicatesSkipped > 0 { parts.append(Self.duplicatesText(summary.duplicatesSkipped)) }
        if let range = plan.stats.dateRange {
            let f = Date.FormatStyle().month(.abbreviated).year()
            parts.append("\(range.lowerBound.formatted(f)) \u{2192} \(range.upperBound.formatted(f))")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func duplicatesText(_ count: Int) -> String {
        count == 1 ? "1 duplicate workout skipped" : "\(count) duplicate workouts skipped"
    }

    private var matchedRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").foregroundStyle(Theme.success)
            Text("\(matchedCount) exercises matched to the library").font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityIdentifier("result.matchedCount")
    }

    private var needsChoiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(unresolved.isEmpty ? "All exercises resolved" : "\(unresolved.count) exercises need a match")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(unresolved.isEmpty ? Theme.success : Theme.record)
            ForEach(Array(plan.needsChoice.enumerated()), id: \.offset) { index, name in
                row(for: name, index: index)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }

    /// Fixed single-line height regardless of resolution, and a solid (not glass) trailing badge: these rows are
    /// CONTENT, which STYLE.md keeps solid for legibility (liquid glass is for the control/navigation layer).
    /// `.contentShape(Rectangle())` matters here: without it, a `Button` label built from `Text + Spacer + Badge`
    /// only reliably registers taps landing on its non-empty subviews, so the second (and later) row in this list
    /// — with more empty `Spacer` room than the first, whose text is longer once resolved — silently ate taps in
    /// that empty space until this was added.
    private func row(for name: String, index: Int) -> some View {
        let resolved = choices[name]
        return Button {
            dialogName = name
        } label: {
            HStack {
                Text(resolved.map { "\(name) \(resolutionSummary($0))" } ?? name)
                    .font(.subheadline).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Badge(text: resolved == nil ? "Match" : "Change", kind: resolved == nil ? .neutral : .success)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.match.\(index)")
    }

    private func resolutionSummary(_ resolution: ImportPlan.Resolution) -> String {
        switch resolution {
        case .library(let id): "\u{2192} " + DisplayName.of(env.library.exercise(id)?.name ?? id)
        case .custom: "\u{2192} Custom exercise"
        case .needsChoice: ""
        }
    }

    /// The preview's count, then what was actually saved (skipped duplicates excluded).
    private var warmupSets: Int { summary?.warmupSets ?? plan.stats.warmupSets }

    private var warmupRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.record)
            Text("\(warmupSets) warm-up \(warmupSets == 1 ? "set" : "sets") kept")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityIdentifier("result.warmups")
    }

    private func primaryAction() {
        guard allResolved else { return }
        if summary != nil {
            onContinue()
            return
        }
        runImport()
    }

    private func runImport() {
        importing = true
        error = nil
        let service = ImportService(workouts: env.workouts, customExercises: env.customExercises,
                                    library: env.library)
        Task {
            do {
                let result = try await service.importAll(plan: plan, choices: choices) { value in progress = value }
                env.libraryChanged()
                env.dataChanged()
                summary = result
            } catch {
                AppEnvironment.log.error("Import failed: \(error.localizedDescription, privacy: .public)")
                self.error = "Couldn't finish the import. Please try again."
            }
            importing = false
        }
    }
}

/// Small glass sheet offering how to resolve one unmatched exported exercise name: confirm a fuzzy suggestion,
/// search the library, or create it as a custom exercise.
private struct MatchOptionsSheet: View {
    let name: String
    let suggestion: Exercise?
    let onUseSuggestion: (String) -> Void
    let onSearch: () -> Void
    let onCustom: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 8)
            VStack(spacing: 4) {
                FieldLabel(text: "Match")
                Text(name).font(.title3.weight(.bold)).foregroundStyle(Theme.textPrimary)
            }
            VStack(spacing: 10) {
                if let suggestion {
                    GlassPillButton(title: "Use \(DisplayName.of(suggestion.name))", identifier: "result.sheet.suggestion") {
                        onUseSuggestion(suggestion.id)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
                GlassPillButton(title: "Search the library", identifier: "result.sheet.search") {
                    onSearch()
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                GlassPillButton(title: "Create as custom exercise", identifier: "result.sheet.custom") {
                    onCustom()
                    dismiss()
                }
                .frame(maxWidth: .infinity)
            }
            Spacer()
        }
        .padding(20)
        .background(Theme.background)
        .presentationDetents([.medium])
    }
}
