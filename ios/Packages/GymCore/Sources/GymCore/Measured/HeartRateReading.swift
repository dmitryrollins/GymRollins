import Foundation

/// One heart-rate value from Apple Health (plan 40), whatever recorded it: the GymRollins watch app, Apple's Workout
/// app, a chest strap. Read on the phone for the workout detail's tiles and charts; never stored or synced (spec
/// decision 11), only the numbers worked out from it are.
public struct HeartRateReading: Equatable, Sendable, Codable {
    public let date: Date
    /// Beats per minute.
    public let bpm: Double

    public init(date: Date, bpm: Double) {
        self.date = date
        self.bpm = bpm
    }
}
