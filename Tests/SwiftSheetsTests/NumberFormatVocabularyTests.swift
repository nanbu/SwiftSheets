import Testing
@testable import SwiftSheets

/// The named number formats are the few codes worth a name, each the code it claims to be; everything else is a code
/// string or a builtin id (spec Appendix B.57).
struct NumberFormatVocabularyTests {
    @Test func everyConstantIsTheCodeItNames() {
        #expect(NumberFormat.general == "General" && NumberFormat.text == "@")
        #expect(NumberFormat.number == "0" && NumberFormat.numberTwoDecimals == "0.00")
        #expect(NumberFormat.numberThousands == "#,##0" && NumberFormat.numberThousandsTwoDecimals == "#,##0.00")
        #expect(NumberFormat.percent == "0%" && NumberFormat.percentTwoDecimals == "0.00%" && NumberFormat.scientific == "0.00E+00")
        #expect(NumberFormat.isoDate == "yyyy-mm-dd" && NumberFormat.isoDateTime == "yyyy-mm-dd h:mm:ss")
        #expect(NumberFormat.time24 == "h:mm" && NumberFormat.time24Seconds == "h:mm:ss" && NumberFormat.minutesSeconds == "mm:ss")
        #expect(NumberFormat.time12 == "h:mm AM/PM" && NumberFormat.time12Seconds == "h:mm:ss AM/PM")
        #expect(NumberFormat.elapsed == "[hh]:mm:ss")
    }

    /// The constants that are also builtins map to the spec's ids, so a file gets the id rather than a custom entry.
    @Test func theBuiltinOnesAreRecognisedAsBuiltins() {
        #expect(NumberFormat.builtinID(NumberFormat.general) == 0 && NumberFormat.builtinID(NumberFormat.number) == 1)
        #expect(NumberFormat.builtinID(NumberFormat.numberTwoDecimals) == 2 && NumberFormat.builtinID(NumberFormat.numberThousands) == 3)
        #expect(NumberFormat.builtinID(NumberFormat.numberThousandsTwoDecimals) == 4 && NumberFormat.builtinID(NumberFormat.percent) == 9)
        #expect(NumberFormat.builtinID(NumberFormat.percentTwoDecimals) == 10 && NumberFormat.builtinID(NumberFormat.scientific) == 11)
        #expect(NumberFormat.builtinID(NumberFormat.time12) == 18 && NumberFormat.builtinID(NumberFormat.time12Seconds) == 19)
        #expect(NumberFormat.builtinID(NumberFormat.time24) == 20 && NumberFormat.builtinID(NumberFormat.time24Seconds) == 21)
        #expect(NumberFormat.builtinID(NumberFormat.minutesSeconds) == 45 && NumberFormat.builtinID(NumberFormat.text) == 49)
        #expect(NumberFormat.builtinCode(14) == "mm-dd-yy", "the locale-shown short date is reached by its id, not by a name")
    }

    /// A value with no format of its own is given the named default for its kind.
    @Test func theDefaultsForDatedValuesAreTheNamedOnes() {
        var sheet = Sheet(name: "S")
        sheet["A1"] = .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 10)!))
        sheet["A2"] = .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 10)!, time: TimeOfDay(hour: 1, minute: 2, second: 3)))
        sheet["A3"] = .time(TimeOfDay(hour: 1, minute: 2, second: 3))
        sheet["A4"] = .duration(.seconds(90_000))
        #expect(sheet[cell: "A1"].numberFormat == NumberFormat.isoDate)
        #expect(sheet[cell: "A2"].numberFormat == NumberFormat.isoDateTime)
        #expect(sheet[cell: "A3"].numberFormat == NumberFormat.time24Seconds)
        #expect(sheet[cell: "A4"].numberFormat == NumberFormat.elapsed)
    }
}
