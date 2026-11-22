import SwiftUI

/// Today's calendar: pick today or a later day to see what it trains. Picking a day closes the sheet. Each day's dot
/// says whether a workout was done (green) or is planned (red), and the month's counts sit underneath (owner,
/// 2026-11-19: see which day is still empty and which is not).
struct TodayDatePickerSheet: View {
    let now: Date
    let days: TrainingCalendar
    let onPick: (TodayDay) -> Void
    @Environment(\.dismiss) private var dismiss
    private let selected: Date
    /// A day in the month shown: the stats row counts that month.
    @State private var month: Date

    init(selected: TodayDay, now: Date, days: TrainingCalendar, onPick: @escaping (TodayDay) -> Void) {
        self.now = now
        self.days = days
        self.onPick = onPick
        let date = selected.date(now: now)
        self.selected = date
        _month = State(initialValue: date)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    TrainingCalendarView(selected: selected, now: now, days: days,
                                         onPick: { pick(TodayDay(date: $0, now: now)) }, onMonth: { month = $0 })
                        .accessibilityIdentifier("today.datePicker")
                    MetricRow(readings: TrainingMonthText.readings(days.stats(forMonthOf: month)), size: .medium,
                              prefix: "today.calendar")
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, Theme.gutter)
            }
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
        .presentationDetents([.large]) // the calendar's rows are tall: the stats row only fits whole
    }

    private func pick(_ day: TodayDay) {
        onPick(day)
        dismiss()
    }
}
