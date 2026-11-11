import SwiftUI

/// "1 exercise swapped for this gym. Your plan isn't changed.", on Today and on a later day.
struct TodayGymNote: View {
    let text: String

    var body: some View {
        Text(text).font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.record)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassCapsule(tint: Theme.record.opacity(0.25), interactive: false)
            .accessibilityIdentifier("today.gymNote")
    }
}
