import GymCore
import GymData
import SwiftUI

/// Onboarding step 1/3: units, height, bodyweight (also saved as the first weigh-in, updated on revisit), goal weight + date,
/// training days, experience and injuries/limits. Validates with the same ranges as the DB (`DomainLimits`).
struct ProfileSetupView: View {
    @Environment(AppEnvironment.self) private var env
    /// The weigh-in this onboarding already saved (owned by `OnboardingFlow`, which outlives this screen), so a
    /// revisit updates it rather than adding another observation.
    @Binding var weighInId: UUID?
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var unit: WeightUnit = .lb
    @State private var heightText = ""
    @State private var bodyweightText = ""
    @State private var goalWeightText = ""
    @State private var goalDate = Date()
    @State private var hasGoalDate = false
    @State private var trainingDays = 4
    @State private var experience = "intermediate"
    @State private var limits = ""
    @State private var error: String?
    @State private var loaded = false

    private static let experiences: [(value: String, label: String)] =
        [("beginner", "Beginner"), ("intermediate", "Intermediate"), ("advanced", "Advanced")]
    private static let dayOptions: [(value: Int, label: String)] = (2...6).map { ($0, "\($0)") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(text: "Step 1 of 3")
                    DisplayTitle(text: "About you", size: 34)
                }
                formFields
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.destructive).accessibilityIdentifier("setup.error")
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 58)
            .padding(.bottom, 90)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            PrimaryGlassButton(title: "Continue", identifier: "setup.continue", action: save)
                .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
        }
        .task { load() }
    }

    private var header: some View {
        HStack {
            OnboardingBackButton(action: onBack)
            Spacer()
            OnboardingProgressDots(step: 1)
        }
    }

    private var formFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Units")
                GlassSegmentedControl(options: [(WeightUnit.lb, "lb plates"), (.kg, "kg plates")],
                                      selection: $unit, identifierPrefix: "setup.units")
            }
            HStack(spacing: 12) {
                field("Height (cm)", text: $heightText, identifier: "setup.height")
                field("Bodyweight (\(unit.rawValue))", text: $bodyweightText, identifier: "setup.bodyweight")
            }
            HStack(spacing: 12) {
                field("Goal weight (\(unit.rawValue))", text: $goalWeightText, identifier: "setup.goalWeight")
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "By")
                    DatePicker("Goal date", selection: $goalDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("setup.goalDate")
                        .onChange(of: goalDate) { _, _ in hasGoalDate = true }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Training days / week")
                GlassSegmentedControl(options: Self.dayOptions, selection: $trainingDays,
                                      identifierPrefix: "setup.trainingDays")
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Experience")
                GlassSegmentedControl(options: Self.experiences, selection: $experience,
                                      identifierPrefix: "setup.experience")
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Injuries / limits")
                TextField("e.g. knee — no leg loading until \u{2026}", text: $limits, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(10)
                    .background(Theme.card, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("setup.limits")
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            TextField(label, text: text)
                .keyboardType(.decimalPad)
                .padding(.horizontal, 14)
                .frame(minHeight: Theme.minTapSize)
                .background(Theme.card, in: .rect(cornerRadius: 12))
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() {
        guard !loaded else { return }
        let p = env.profile
        unit = p.unit
        if let h = p.heightCm { heightText = Self.number(h) }
        if let latest = try? env.body.latest() {
            bodyweightText = Self.number(UnitConverter.fromKg(latest.weightKg, to: unit))
        }
        if let g = p.goalWeightKg { goalWeightText = Self.number(UnitConverter.fromKg(g, to: unit)) }
        if let d = p.goalDate { goalDate = d; hasGoalDate = true }
        trainingDays = p.trainingDays
        experience = p.experience
        limits = p.limits
        loaded = true
    }

    private func save() {
        let input: ProfileSetupInput
        switch ProfileSetupInput.parse(bodyweight: bodyweightText, height: heightText, goalWeight: goalWeightText,
                                       unit: unit) {
        case .success(let parsed): input = parsed
        case .failure(let invalid):
            error = invalid.message
            return
        }
        if let violation = DomainLimits.profileViolation(
            restSec: env.profile.restSec, warmupRestSec: env.profile.warmupRestSec, heightCm: input.heightCm,
            goalWeightKg: input.goalWeightKg, trainingDays: trainingDays, limits: limits,
            deloadPct: env.profile.deloadPct) {
            error = violation
            return
        }
        if let violation = DomainLimits.bodyweightViolation(weightKg: input.bodyweightKg, bodyFatPct: nil) {
            error = violation
            return
        }
        let current = env.profile.withStandardEquipment(for: unit)
        let profile = Profile(unit: unit, restSec: current.restSec, warmupRestSec: current.warmupRestSec,
                              heightCm: input.heightCm, goalWeightKg: input.goalWeightKg,
                              goalDate: (input.goalWeightKg != nil && hasGoalDate) ? GoalDate.normalized(goalDate) : nil,
                              trainingDays: trainingDays, experience: experience, limits: limits,
                              deloadPct: current.deloadPct, barKg: current.barKg, plateInventory: current.plateInventory,
                              dumbbellStepKg: current.dumbbellStepKg, mcpReadWorkouts: current.mcpReadWorkouts,
                              mcpReadBody: current.mcpReadBody, mcpReadPlan: current.mcpReadPlan,
                              mcpPropose: current.mcpPropose, mcpAutoApply: current.mcpAutoApply)
        do {
            try env.profiles.save(profile)
            weighInId = try OnboardingWeighIn.save(weightKg: input.bodyweightKg, date: env.now(), reusing: weighInId,
                                                   in: env.body)
            env.reloadProfile()
            env.dataChanged()
            error = nil
            onContinue()
        } catch {
            AppEnvironment.log.error("Save profile failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save your profile. Please try again."
        }
    }

    private static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
