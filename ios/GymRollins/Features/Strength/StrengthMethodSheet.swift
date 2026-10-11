import GymCore
import SwiftUI

/// How strength levels are computed: your inputs (editable), each lift's thresholds in your unit, the method and
/// the data source.
struct StrengthMethodSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State var report: StrengthReport?
    @State private var showProfile = false

    private var unit: WeightUnit { env.profile.unit }
    private var standards: StrengthStandards? { BundledStrengthStandards.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputsCard
                    if let report, report.rows.contains(where: { $0.assessment != nil }) {
                        thresholdsCard(report)
                    }
                    methodCard
                    sourceCard
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .navigationTitle("Strength Levels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("strength.method.done")
                }
            }
            .sheet(isPresented: $showProfile, onDismiss: { report = env.strengthReport() }, content: {
                StrengthProfileSheet().presentationDetents([.medium, .large])
            })
        }
        .accessibilityIdentifier("strength.method")
    }

    private var inputsCard: some View {
        SolidCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Compared as")
                Text(StrengthText.inputs(sex: env.profile.sex, age: report?.age, bodyweightKg: report?.bodyweightKg,
                                         unit: unit))
                    .font(.headline).foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("strength.method.inputs")
                Text("Bodyweight is your latest weigh-in; age is this year minus your birth year. "
                     + StrengthText.privacy)
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                GlassPillButton(title: env.profile.sex == nil ? "Add sex & birth year" : "Edit sex & birth year",
                                systemImage: "pencil", identifier: "strength.method.editProfile") { showProfile = true }
            }
        }
    }

    private func thresholdsCard(_ report: StrengthReport) -> some View {
        SolidCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Your thresholds")
                ForEach(report.rows.filter { $0.assessment != nil }) { row in
                    if let a = row.assessment {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.lift.displayName).font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            ForEach(StrengthLevel.allCases.dropFirst()) { level in
                                HStack {
                                    Text(level.displayName).foregroundStyle(level == a.level ? Theme.accent
                                                                            : Theme.textSecondary)
                                    Spacer()
                                    Text(StrengthText.weight(a.thresholds[level] ?? 0, unit: unit))
                                        .monospacedDigit().foregroundStyle(Theme.textPrimary)
                                }
                                .font(.footnote)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("strength.method.thresholds.\(row.lift.rawValue)")
                    }
                }
            }
        }
    }

    private var methodCard: some View {
        SolidCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "How it works")
                ForEach(Self.methodLines, id: \.self) { line in
                    Text(line).font(.footnote).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sourceCard: some View {
        SolidCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Data")
                Text(StrengthText.credit).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                if let source = standards?.source {
                    Text("\(source.name) data of \(source.version) (openpowerlifting.org).")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("strength.method.source")
                }
            }
        }
    }

    static let methodLines = [
        "Your estimated 1RM is the best set of the last 12 months (Epley, 1\u{2013}12 reps, warm-ups excluded) "
            + "of the barbell back squat, bench press, and deadlift (conventional or sumo).",
        "It is compared with raw (no suits or knee wraps) powerlifting competitors of your sex, age group and "
            + "bodyweight since 2012, counting each lifter's best meet once.",
        "Competitors out-lift most gym-goers, so Novice and Intermediate start at 45% and 65% of the competitors' "
            + "median lift, Advanced at their 20th percentile and Elite at their 80th.",
        "A knee or leg note in your limits pauses squat and deadlift here; the numbers stay visible."
    ]
}
