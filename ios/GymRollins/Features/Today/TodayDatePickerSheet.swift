import SwiftUI

/// Today's calendar: pick today or a later day to see what it trains. Picking a day closes the sheet.
struct TodayDatePickerSheet: View {
    let now: Date
    let onPick: (TodayDay) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(selected: TodayDay, now: Date, onPick: @escaping (TodayDay) -> Void) {
        self.now = now
        self.onPick = onPick
        _date = State(initialValue: selected.date(now: now))
    }

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $date, in: Calendar.current.startOfDay(for: now)...,
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Theme.primaryFill)
                .padding(.horizontal, Theme.gutter)
                .accessibilityIdentifier("today.datePicker")
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Pick a day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Today") { pick(.today) }.accessibilityIdentifier("today.datePicker.today")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: date) { _, new in pick(TodayDay(date: new, now: now)) }
    }

    private func pick(_ day: TodayDay) {
        onPick(day)
        dismiss()
    }
}
