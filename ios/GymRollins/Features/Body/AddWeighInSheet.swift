import GymCore
import GymData
import GymHealth
import SwiftUI

/// Glass sheet to log a bodyweight entry: a big kg field with ±0.1 steppers, a date, an optional
/// body-fat %, a "Morning" toggle, and a disabled "Apple Health" row. Validates 30–300 kg and
/// 3–60% body fat (`DomainLimits`, matching the DB constraints).
struct AddWeighInSheet: View {
    let defaultKg: Double
    let now: Date
    let onSaved: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var valueText: String
    @State private var date: Date
    @State private var bodyFatText = ""
    @State private var morning = true
    @State private var error: String?

    init(defaultKg: Double, now: Date, onSaved: @escaping () -> Void) {
        self.defaultKg = defaultKg
        self.now = now
        self.onSaved = onSaved
        _valueText = State(initialValue: WeightFormatter.number(defaultKg))
        _date = State(initialValue: now)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5)
                DisplayTitle(text: "Add weigh-in", size: 28)
                weightField
                DatePicker("Date", selection: $date, in: ...now, displayedComponents: .date)
                    .labelsHidden()
                bodyFatField
                Toggle("Morning", isOn: $morning).accessibilityIdentifier("weighin.morning")
                healthRow
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.destructive).accessibilityIdentifier("weighin.error")
                }
                PrimaryGlassButton(title: "Save", identifier: "weighin.save", action: save)
            }
            .padding(22)
        }
        .background(Theme.background)
        .presentationDetents([.large])
        .task { await env.health.refreshPermissions() }
    }

    private var weightField: some View {
        HStack(spacing: 18) {
            Button { adjust(-0.1) } label: { Image(systemName: "minus") }
                .glassCircle()
                .accessibilityLabel("Decrease by 0.1")
                .accessibilityIdentifier("weighin.minus")
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                TextField("Weight", text: $valueText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.display(56))
                    .frame(width: 130)
                    .accessibilityIdentifier("weighin.value")
                Text("kg").font(.title3).foregroundStyle(Theme.textSecondary)
            }
            Button { adjust(0.1) } label: { Image(systemName: "plus") }
                .glassCircle()
                .accessibilityLabel("Increase by 0.1")
                .accessibilityIdentifier("weighin.plus")
        }
    }

    private var bodyFatField: some View {
        HStack {
            Text("Body fat % (optional)").foregroundStyle(Theme.textSecondary)
            Spacer()
            TextField("\u{2014}", text: $bodyFatText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                .accessibilityIdentifier("weighin.bodyFat")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .glassCapsule(interactive: false)
    }

    /// Weigh-ins follow the Apple Health setting (Settings → Apple Health): no per-entry switch.
    private var healthRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if env.health.isEnabled && env.health.permissions.permission(.bodyMass) == .authorized {
                Label("Also saved to Apple Health", systemImage: "heart.fill")
                    .font(.subheadline).foregroundStyle(Theme.success)
            } else if env.health.isEnabled {
                Text("Apple Health isn't allowed to save weight").font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Text("Allow Weight in Settings \u{2192} Health \u{2192} Data Access & Devices \u{2192} GymRollins.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            } else {
                Text("Apple Health sync is off").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Text("Turn it on in Settings \u{2192} Apple Health to save weigh-ins there.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("weighin.health")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adjust(_ delta: Double) {
        let current = parsedValue() ?? defaultKg
        valueText = WeightFormatter.number(current + delta)
    }

    private func parsedValue() -> Double? {
        LocalizedNumber.parse(valueText)
    }

    private func save() {
        guard let weight = parsedValue(), DomainLimits.bodyweightKg.contains(weight) else {
            error = DomainLimits.bodyweightViolation(weightKg: -1, bodyFatPct: nil)
            return
        }
        var bodyFat: Double?
        let trimmedFat = bodyFatText.trimmingCharacters(in: .whitespaces)
        if !trimmedFat.isEmpty {
            guard let fat = LocalizedNumber.parse(trimmedFat),
                  DomainLimits.bodyFatPct.contains(fat) else {
                error = DomainLimits.bodyweightViolation(weightKg: weight, bodyFatPct: -1)
                return
            }
            bodyFat = fat
        }
        do {
            try env.body.add(BodyweightEntry(date: date, weightKg: weight, bodyFatPct: bodyFat,
                                             timeOfDay: morning ? "morning" : nil))
            env.dataChanged()
            error = nil
            onSaved()
            dismiss()
        } catch {
            self.error = "Couldn't save. Try again."
        }
    }
}
