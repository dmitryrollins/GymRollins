import GymCore
import GymHealth
import SwiftUI

enum CalorieText {
    /// "≈ 320 kcal".
    static func kcal(_ value: Int) -> String { "\u{2248} \(value.formatted()) kcal" }
}

/// The full-width "≈ 320 kcal (estimated)" tile on the workout Summary and detail, with the ⓘ method sheet and,
/// when Apple Health is on, whether the workout is saved there.
struct CalorieCard: View {
    let estimate: CalorieEstimate?
    let healthStatus: HealthSync.ExportStatus
    /// `summary` / `detail`: identifiers become `<prefix>.kcal`, `<prefix>.kcal.info`, `<prefix>.health`.
    let prefix: String
    @State private var showInfo = false

    var body: some View {
        if estimate != nil || healthInfo != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let estimate { kcalRow(estimate) }
                healthLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.card, in: .rect(cornerRadius: 14))
            .sheet(isPresented: $showInfo) { CalorieInfoSheet(estimate: estimate) }
        }
    }

    private func kcalRow(_ estimate: CalorieEstimate) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calories").font(.caption).foregroundStyle(Theme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(CalorieText.kcal(estimate.kcal)).font(Theme.display(28)).foregroundStyle(Theme.textPrimary)
                    Text(estimate.usedDefaultBodyWeight ? "(estimated, 70 kg)" : "(estimated)")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(prefix).kcal")
            Spacer()
            Button { showInfo = true } label: { Image(systemName: "info.circle") }
                .glassCircle()
                .accessibilityLabel("How calories are estimated")
                .accessibilityIdentifier("\(prefix).kcal.info")
        }
    }

    @ViewBuilder
    private var healthLine: some View {
        if let info = healthInfo {
            Label(info.text, systemImage: info.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(info.color)
                .accessibilityIdentifier("\(prefix).health")
        }
    }

    private var healthInfo: (text: String, icon: String, color: Color)? {
        switch healthStatus {
        case .notEnabled, .notEligible: nil
        case .pending: ("Saving to Apple Health\u{2026}", "heart", Theme.textSecondary)
        case .saved: ("Saved to Apple Health", "heart.fill", Theme.success)
        case .failed: ("Couldn't save to Apple Health", "exclamationmark.triangle", Theme.destructive)
        }
    }
}

/// How the estimate is made, what it used for this workout, and the Compendium citation.
struct CalorieInfoSheet: View {
    let estimate: CalorieEstimate?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    paragraph("Calories are an estimate: MET \u{00D7} body weight (kg) \u{00D7} active hours, using "
                              + "MET values from the 2024 Adult Compendium of Physical Activities. Paused time "
                              + "isn't counted.")
                    paragraph("Each exercise maps to a Compendium activity (weights, supersets, circuits, "
                              + "calisthenics or the cardio you did). Effort comes from your logged RPE/RIR, or from "
                              + "how much rest you took between sets. Logged cardio minutes count as they are; the "
                              + "rest of the workout is shared by working sets.")
                    paragraph("Apple Health gets the active part only, (MET \u{2212} 1) \u{00D7} body weight \u{00D7} "
                              + "hours: Health counts your resting energy separately.")
                    if let estimate { usedCard(estimate) }
                    SectionLabel(text: "Source")
                    paragraph(env.calories.table?.source.citation ?? "2024 Adult Compendium of Physical Activities")
                    Link("pacompendium.com", destination: URL(string: "https://pacompendium.com/")!)
                        .font(.subheadline)
                        .accessibilityIdentifier("calories.info.link")
                    paragraph("Your real energy use depends on fitness, technique and body composition; treat the "
                              + "number as a guide.")
                }
                .padding(Theme.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .navigationTitle("Calories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("calories.info.done")
                }
            }
        }
        .accessibilityIdentifier("calories.info")
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
    }

    private func usedCard(_ estimate: CalorieEstimate) -> some View {
        SolidCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "This workout")
                Text(weightLine(estimate)).font(.footnote).foregroundStyle(Theme.textSecondary)
                Text("\(DurationFormatter.minutes(estimate.activeSeconds)) active \u{00B7} \(estimate.effort.rawValue) effort"
                     + (estimate.wasCapped ? " \u{00B7} capped at 4 h" : ""))
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                ForEach(estimate.parts, id: \.code) { part in
                    Text(partLine(part)).font(.footnote).foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private func weightLine(_ estimate: CalorieEstimate) -> String {
        estimate.usedDefaultBodyWeight
            ? "No weigh-in yet: using 70 kg. Add one on the Body tab for a better estimate."
            : "Body weight: \(WeightFormatter.number(estimate.bodyWeightKg)) kg (your latest weigh-in before this workout)"
    }

    private func partLine(_ part: CalorieEstimate.Part) -> String {
        let name = env.calories.table?.activity(for: part.code)?.description ?? part.code
        return "\(part.code) \u{00B7} \(name) \u{00B7} \(WeightFormatter.number(part.met)) MET \u{00B7} "
            + "\(Int(part.minutes.rounded())) min \u{00B7} \(Int(part.kcal.rounded())) kcal"
    }
}
