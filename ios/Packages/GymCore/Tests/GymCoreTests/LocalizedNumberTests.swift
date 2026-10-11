import GymCore
import Testing

@Suite struct LocalizedNumberTests {
    @Test(arguments: [("82,5", 82.5), ("82.5", 82.5), (" 82 ", 82.0), ("\t180,25\n", 180.25), ("0", 0.0)])
    func parsesDotCommaAndWhitespace(text: String, expected: Double) {
        #expect(LocalizedNumber.parse(text) == expected)
    }

    @Test(arguments: ["", "   ", "abc", "82,5,1", "1.2.3", "nan", "inf", "-inf"])
    func rejectsEmptyInvalidAndNonFinite(text: String) {
        #expect(LocalizedNumber.parse(text) == nil)
    }
}
