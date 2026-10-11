import Foundation
import SwiftData

@Model
public final class CustomExerciseRecord {
    @Attribute(.unique) public var id: String
    public var name: String
    public var bodyPart: String
    public var equipment: String
    public var target: String
    public var modeRaw: String
    public var bilateral: Bool
    public var updatedAt: Date
    public var serverUpdatedAt: Date?
    public var dirty: Bool
    public var deletedAt: Date?

    public init(id: String, name: String, bodyPart: String, equipment: String, target: String, modeRaw: String,
                bilateral: Bool, now: Date) {
        self.id = id
        self.name = name
        self.bodyPart = bodyPart
        self.equipment = equipment
        self.target = target
        self.modeRaw = modeRaw
        self.bilateral = bilateral
        self.updatedAt = now
        self.dirty = true
    }
}
