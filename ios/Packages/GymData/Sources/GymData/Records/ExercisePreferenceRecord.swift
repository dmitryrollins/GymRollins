import Foundation
import SwiftData

/// The owner's recommendation preference for one exercise (`public.exercise_prefs`). `normal` is stored rather than
/// deleted, so resetting a preference syncs like any other edit.
@Model
public final class ExercisePreferenceRecord {
    /// The library or custom exercise id.
    @Attribute(.unique) public var id: String
    public var prefRaw: String
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool

    public init(id: String, prefRaw: String, now: Date) {
        self.id = id
        self.prefRaw = prefRaw
        self.updatedAt = now
        self.dirty = true
    }
}
