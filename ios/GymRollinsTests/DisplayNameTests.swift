import Testing
@testable import GymRollins

@Suite struct DisplayNameTests {
    @Test(arguments: [
        ("barbell bench press", "Barbell Bench Press"),
        ("cable overhead triceps extension (rope attachment)", "Cable Overhead Triceps Extension (Rope Attachment)"),
        ("sled 45° leg press", "Sled 45° Leg Press"),
        ("ez-bar close-grip bench press", "EZ-Bar Close-Grip Bench Press"),
        ("dumbbell incline bench press v. 2", "Dumbbell Incline Bench Press V. 2"),
    ])
    func titleCases(input: String, expected: String) {
        #expect(DisplayName.of(input) == expected)
    }
}
