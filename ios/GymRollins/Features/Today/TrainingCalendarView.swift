import SwiftUI
import UIKit

/// The system calendar (`UICalendarView`, the graphical date picker's own view) with a dot under each day that has a
/// finished workout (Fitness' green) or a planned one (the red action colour). Days before today keep their dots but
/// can't be picked: Today never shows a past day.
struct TrainingCalendarView: UIViewRepresentable {
    let selected: Date
    let now: Date
    let days: TrainingCalendar
    let onPick: (Date) -> Void
    /// A day in the month shown, each time the calendar pages to another.
    let onMonth: (Date) -> Void

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        let calendar = days.calendar
        view.calendar = calendar
        view.locale = .current
        // The coral, as the date picker had: the dark red fill measured 2.4:1 under the chosen day's number.
        view.tintColor = UIColor(Theme.accent)
        view.availableDateRange = DateInterval(start: calendar.startOfDay(for: now), end: .distantFuture)
        view.visibleDateComponents = calendar.dateComponents([.calendar, .era, .year, .month], from: selected)
        view.delegate = context.coordinator
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        selection.selectedDate = calendar.dateComponents([.calendar, .era, .year, .month, .day], from: selected)
        view.selectionBehavior = selection
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.parent = self
    }

    /// The calendar's own height for the width offered (it lays out with Auto Layout).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        let fitted = uiView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required,
                                                    verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: fitted.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: TrainingCalendarView
        init(_ parent: TrainingCalendarView) { self.parent = parent }

        func calendarView(_ calendarView: UICalendarView,
                          decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let date = parent.days.calendar.date(from: dateComponents) else { return nil }
            switch parent.days.status(on: date) {
            case .done: return .default(color: UIColor(Theme.Metric.workout), size: .medium)
            case .planned: return .default(color: UIColor(Theme.accent), size: .medium)
            case .empty: return nil
            }
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let dateComponents, let date = parent.days.calendar.date(from: dateComponents) else { return }
            parent.onPick(date)
        }

        func calendarView(_ calendarView: UICalendarView, didChangeVisibleDateComponentsFrom previous: DateComponents) {
            guard let month = parent.days.calendar.date(from: calendarView.visibleDateComponents) else { return }
            parent.onMonth(month)
        }
    }
}

/// The calendar's stats row for the month shown, coloured like its dots: done in Fitness' green, planned in the red
/// action colour, and the days still empty in plain text.
enum TrainingMonthText {
    static func readings(_ stats: TrainingCalendar.MonthStats) -> [MetricReading] {
        [reading("done", "Done", stats.done, .workout),
         reading("planned", "Planned", stats.planned, .accent),
         reading("empty", "Empty", stats.empty, .primary)]
    }

    private static func reading(_ key: String, _ label: String, _ count: Int, _ tint: MetricTint) -> MetricReading {
        MetricReading(key: key, label: label, value: "\(count)", unit: nil,
                      spoken: count == 1 ? "1 day" : "\(count) days", tint: tint)
    }
}
