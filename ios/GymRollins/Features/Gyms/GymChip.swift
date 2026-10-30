import GymCore
import GymData
import SwiftUI

/// Today's gym chip with the picker it opens and the one-shot "You're at X?" suggestion below it.
struct GymChipRow: View {
    @Environment(AppEnvironment.self) private var env
    let gym: Gym?
    @State private var showPicker = false
    @State private var suggestion: NearbyGym?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chip
            if let suggestion { suggestionCard(suggestion) }
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.destructive) }
        }
        .sheet(isPresented: $showPicker) { GymPickerView() }
        .task {
            // The throttle answers nil on a return to Today: that must not remove a card nobody dismissed.
            if let found = await env.suggestNearbyGym() { suggestion = found }
        }
        .onChange(of: gym?.id) { _, _ in suggestion = nil }
        .onChange(of: env.gymRevision) { _, _ in dropSuggestionIfItsGymIsGone() }
    }

    private var chip: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                Text(gym?.name ?? "Choose gym").lineLimit(2).multilineTextAlignment(.leading)
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(minHeight: Theme.minTapSize - 16)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Gym: \(gym?.name ?? "none")")
        .accessibilityHint("Opens the gym picker")
        .accessibilityIdentifier("today.gymChip")
    }

    private func suggestionCard(_ nearby: NearbyGym) -> some View {
        HStack(spacing: 8) {
            Text("You're at \(nearby.name)?").font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Train here") { accept(nearby) }
                .buttonStyle(.glassProminent).tint(Theme.primaryFill)
                .accessibilityIdentifier("today.gymSuggestion.accept")
            Button { suggestion = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("today.gymSuggestion.dismiss")
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.gymSuggestion")
    }

    private func dropSuggestionIfItsGymIsGone() {
        guard let suggestion, case .saved(let saved) = suggestion.target else { return }
        do {
            if try env.gyms.gym(saved.id) == nil { self.suggestion = nil }
        } catch {
            AppEnvironment.log.error("Read gym failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func accept(_ nearby: NearbyGym) {
        do {
            try env.trainHere(nearby)
            suggestion = nil
            errorText = nil
        } catch {
            AppEnvironment.log.error("Train here failed: \(error.localizedDescription, privacy: .public)")
            if case GymChoiceError.gymGone = error { suggestion = nil }
            errorText = (error as? GymChoiceError)?.errorDescription ?? "Couldn't switch gyms. Try again."
        }
    }
}
