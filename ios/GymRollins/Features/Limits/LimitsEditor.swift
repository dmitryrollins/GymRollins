import SwiftUI

/// The injury note and its optional end date, in first-time setup and Settings.
struct LimitsEditor: View {
    @Binding var note: String
    @Binding var hasDate: Bool
    @Binding var until: Date
    let dates: ClosedRange<Date>
    /// The note field's identifier; the toggle and the picker add `.hasDate` and `.until`.
    let identifier: String

    private var noteIsEmpty: Bool { note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(text: "Injuries / limits")
            TextField("e.g. knee \u{2014} no leg loading", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .padding(10)
                .background(Theme.card, in: .rect(cornerRadius: 12))
                .accessibilityIdentifier(identifier)
            Toggle("Until", isOn: $hasDate)
                .disabled(noteIsEmpty)
                .tint(Theme.accent)
                .frame(minHeight: Theme.minTapSize)
                .accessibilityIdentifier("\(identifier).hasDate")
            if hasDate && !noteIsEmpty {
                DatePicker("End date", selection: $until, in: dates, displayedComponents: .date)
                    .tint(Theme.accent)
                    .frame(minHeight: Theme.minTapSize)
                    .accessibilityIdentifier("\(identifier).until")
            }
        }
        .onChange(of: noteIsEmpty) { _, empty in if empty { hasDate = false } }
    }
}
