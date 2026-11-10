public extension Exercise {
    /// Equipment that's loaded as a fixed bar plus plates, so it only moves in barbell increments.
    static let barbellLoadedEquipment: Set<String> = [
        "barbell", "olympic barbell", "ez barbell", "smith machine", "trap bar",
    ]

    /// True for barbell-type equipment (barbell increments and rounding); false for dumbbells, machines, cables,
    /// bodyweight and the rest.
    var isBarbellLoaded: Bool { Self.barbellLoadedEquipment.contains(equipment) }
}
