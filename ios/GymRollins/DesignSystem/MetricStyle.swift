import SwiftUI

/// Apple Fitness' look for measured values (plan 39 §4.1): each value in its metric's colour, SF Pro Rounded semibold,
/// its unit uppercase and smaller right after it ("2.26KM"), a plain label above. Digits stay proportional, as in
/// Fitness' summary: these values don't tick, and tabular digits left a gap after every 1 ("1 38W").
extension Theme {
    /// Every colour keeps at least 4.5:1 on `Theme.card` and `Theme.background` (the lowest, `calories`, is 5.6:1 on
    /// the card), so even the small units pass the accessibility audit.
    enum Metric {
        /// The kind icon and the headline metric (Fitness' green-yellow).
        static let workout = Color(hex: 0xB6F23A)
        /// The round icon's fill: a dark tint of `workout` (10:1 with it).
        static let workoutFill = Color(hex: 0x26330F)
        static let time = Color(hex: 0xF6E23B)
        static let distance = Color(hex: 0x40A8F5)
        /// Active and total calories, Move. Apple's 0xFA114F is under 4.5:1 on the card.
        static let calories = Color(hex: 0xFF4F6D)
        static let heartRate = Color(hex: 0xFF6961)
        static let power = Color(hex: 0xB6F23A)
        static let cadence = Color(hex: 0x5EE0E6)
        static let steps = Color(hex: 0xA98BFF)
        static let exercise = Color(hex: 0xA6F23A)
        static let stand = Color(hex: 0x3FE6EF)
    }
}

/// Which `Theme.Metric` colour a value is drawn in. Plain data, so the text that picks it stays unit-testable.
enum MetricTint: Equatable, Sendable {
    case workout, time, distance, calories, heartRate, power, cadence, steps, exercise, stand

    var color: Color {
        switch self {
        case .workout: Theme.Metric.workout
        case .time: Theme.Metric.time
        case .distance: Theme.Metric.distance
        case .calories: Theme.Metric.calories
        case .heartRate: Theme.Metric.heartRate
        case .power: Theme.Metric.power
        case .cadence: Theme.Metric.cadence
        case .steps: Theme.Metric.steps
        case .exercise: Theme.Metric.exercise
        case .stand: Theme.Metric.stand
        }
    }
}

/// One measured value as a cell shows it: "Distance" over "2.26" + "KM", read by VoiceOver as "Distance, 2.26
/// kilometres".
struct MetricReading: Equatable, Identifiable, Sendable {
    /// Stable per kind of value; the cell's accessibility identifier ends with it ("outside.distance").
    let key: String
    let label: String
    let value: String
    /// Uppercase ("KM", "KCAL"); nil when the label says it all (steps, a clock time).
    let unit: String?
    /// The value with its unit in full, for VoiceOver ("2.26 kilometres").
    let spoken: String
    let tint: MetricTint

    var id: String { key }
}

/// How big a metric is drawn. Each size pairs a value text style with a unit style about 60 % of it, so both scale
/// with Dynamic Type.
enum MetricSize {
    /// The detail's grid and headline: title (28 pt) with a body unit (17 pt).
    case large
    /// The Log card's headline: title2 (22 pt) with a footnote unit (13 pt).
    case medium
    /// Today's row and the measured block: title3 (20 pt) with a caption unit (12 pt).
    case compact
    /// The 7-day sheet: body (17 pt) with a caption2 unit (11 pt).
    case small

    var valueFont: Font {
        switch self {
        case .large: .system(.title, design: .rounded, weight: .semibold)
        case .medium: .system(.title2, design: .rounded, weight: .semibold)
        case .compact: .system(.title3, design: .rounded, weight: .semibold)
        case .small: .system(.body, design: .rounded, weight: .semibold)
        }
    }

    var unitFont: Font {
        switch self {
        case .large: .system(.body, design: .rounded, weight: .semibold)
        case .medium: .system(.footnote, design: .rounded, weight: .semibold)
        case .compact: .system(.caption, design: .rounded, weight: .semibold)
        case .small: .system(.caption2, design: .rounded, weight: .semibold)
        }
    }

    var labelFont: Font {
        switch self {
        case .large: .body
        case .medium: .subheadline
        case .compact: .footnote
        case .small: .caption
        }
    }
}

/// "2.26KM": the value, then its unit in the same colour, smaller and with no space between.
struct MetricValueText: View {
    let reading: MetricReading
    var size: MetricSize = .large
    /// Overrides the reading's own colour (the headline is drawn in `workout`).
    var tint: MetricTint?

    var body: some View {
        Group {
            if let unit = reading.unit {
                Text("\(Text(reading.value).font(size.valueFont))\(Text(unit).font(size.unitFont))")
            } else {
                Text(reading.value).font(size.valueFont)
            }
        }
        .foregroundStyle((tint ?? reading.tint).color)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// A labelled metric: the label in plain primary text over the coloured value. One accessibility element that speaks
/// the unit in full.
struct MetricCell: View {
    let reading: MetricReading
    var size: MetricSize = .large
    /// The accessibility identifier is `"\(prefix).\(reading.key)"`.
    let prefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(reading.label).font(size.labelFont).foregroundStyle(Theme.textPrimary)
            MetricValueText(reading: reading, size: size)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.label)
        .accessibilityValue(reading.spoken)
        .accessibilityIdentifier("\(prefix).\(reading.key)")
    }
}

/// Metrics two to a row, flowing on when one is missing; one to a row at accessibility text sizes.
struct MetricGrid: View {
    let readings: [MetricReading]
    var size: MetricSize = .large
    let prefix: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                            count: typeSize.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: columns, alignment: .leading, spacing: size == .large ? 18 : 12) {
            ForEach(readings) { MetricCell(reading: $0, size: size, prefix: prefix) }
        }
    }
}

/// Metrics side by side in one row, spread across it, while they fit whole; else as a `MetricGrid`.
struct MetricRow: View {
    let readings: [MetricReading]
    var size: MetricSize = .compact
    let prefix: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(readings) { reading in
                    MetricCell(reading: reading, size: size, prefix: prefix).fixedSize()
                    if reading.id != readings.last?.id { Spacer(minLength: 12) }
                }
            }
            MetricGrid(readings: readings, size: size, prefix: prefix)
        }
    }
}

/// The kind's symbol in `workout` colour inside a round dark tint of it, like Fitness' workout icon. Decorative.
struct MetricIcon: View {
    let symbol: String
    var diameter: CGFloat = Theme.minTapSize

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.45, weight: .semibold))
            .foregroundStyle(Theme.Metric.workout)
            .frame(width: diameter, height: diameter)
            .background(Theme.Metric.workoutFill, in: .circle)
            .accessibilityHidden(true)
    }
}
