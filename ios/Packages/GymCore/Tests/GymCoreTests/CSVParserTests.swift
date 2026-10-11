import Testing
@testable import GymCore

@Suite struct CSVParserTests {
    @Test func simpleRows() {
        #expect(CSVParser.parse("a,b,c\n1,2,3\n") == [["a", "b", "c"], ["1", "2", "3"]])
    }

    @Test func quotedFieldsWithCommasQuotesAndNewlines() {
        let text = "name,note\n\"Bench, flat\",\"said \"\"easy\"\"\"\nx,\"two\nlines\"\n"
        #expect(CSVParser.parse(text) == [["name", "note"], ["Bench, flat", "said \"easy\""], ["x", "two\nlines"]])
    }

    @Test func crlfAndMissingTrailingNewline() {
        #expect(CSVParser.parse("a,b\r\n1,2") == [["a", "b"], ["1", "2"]])
    }

    @Test func emptyFieldsKept() {
        #expect(CSVParser.parse("a,,c\n") == [["a", "", "c"]])
    }

    @Test func blankLinesSkipped() {
        #expect(CSVParser.parse("a\n\nb\n") == [["a"], ["b"]])
    }

    @Test func midFieldQuoteIsLiteral() {
        // RFC 4180: a `"` only starts a quoted field when it is the FIRST character of the field.
        #expect(CSVParser.parse(#"a,b said "hi" ok,c"#) == [["a", "b said \"hi\" ok", "c"]])
    }

    @Test func midFieldQuoteWithTrailingQuoteIsLiteral() {
        let text = "a,3\" bar,c\nrow2,d,e\n"
        #expect(CSVParser.parse(text) == [["a", "3\" bar", "c"], ["row2", "d", "e"]])
    }

    @Test func stripsLeadingUTF8BOM() {
        #expect(CSVParser.parse("\u{FEFF}a,b\n1,2\n") == [["a", "b"], ["1", "2"]])
    }

    @Test func loneCarriageReturnEndsRowOutsideQuotes() {
        #expect(CSVParser.parse("a,b\rc,d\r") == [["a", "b"], ["c", "d"]])
    }

    @Test func recordsTrackTrueSourceLineAcrossBlankLines() {
        let records = CSVParser.records("a\n\nb\n")
        #expect(records.map(\.line) == [1, 3])
        #expect(records.map(\.fields) == [["a"], ["b"]])
    }

    @Test func quotedMultilineFieldShiftsFollowingLineNumbers() {
        let text = "name,note\nx,\"two\nlines\"\ny,z\n"
        let records = CSVParser.records(text)
        #expect(records.map(\.line) == [1, 2, 4])
        #expect(records[1].fields == ["x", "two\nlines"])
        #expect(records[2].fields == ["y", "z"])
    }

    @Test func parseIsRecordsFieldsProjection() {
        let text = "a,b\n\nc,\"d\ne\"\nf,g\n"
        #expect(CSVParser.parse(text) == CSVParser.records(text).map(\.fields))
    }

    @Test func semicolonDelimiterKeepsQuotedSemicolonsAndDecimalCommas() {
        let text = "a;b;c\n\"x;y\";60,5;\"q\"\"\"\n"
        #expect(CSVParser.parse(text, delimiter: ";") == [["a", "b", "c"], ["x;y", "60,5", "q\""]])
    }

    @Test func tabDelimiter() {
        #expect(CSVParser.parse("a\tb\n1\t2\n", delimiter: "\t") == [["a", "b"], ["1", "2"]])
    }

    @Test func detectsDelimiterFromHeaderLine() {
        #expect(CSVParser.detectDelimiter("Date;Workout Name;Exercise Name\n1,5;x;y") == ";")
        #expect(CSVParser.detectDelimiter("Date,Workout Name,Exercise Name\n1;2;3;4;5") == ",")
        #expect(CSVParser.detectDelimiter("a\tb\tc\n") == "\t")
        #expect(CSVParser.detectDelimiter("\u{FEFF}a;b\n") == ";")
        #expect(CSVParser.detectDelimiter("\n\r\n\u{FEFF}a;b;c\n1,2") == ";") // leading blank lines
        #expect(CSVParser.detectDelimiter("single") == ",")
        #expect(CSVParser.detectDelimiter("") == ",")
    }

    @Test func delimiterDetectionIgnoresQuotedCharacters() {
        #expect(CSVParser.detectDelimiter("\"a,b,c,d\";x;y\n") == ";")
    }
}
