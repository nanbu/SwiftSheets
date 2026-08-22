import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX

// Ports of openpyxl/utils/tests — same inputs and expectations, Swift API. Each test names its origin
// as `// openpyxl: <file>::<test>` so Tests/OpenpyxlParity/check.py can cross-check the ledger.
// Integer rows / columns are 0-based in the new API (`CellRef`, `CellRange`, `RangeBounds`); A1 strings are unchanged.

@Suite struct UtilsCellParityTests {
    // openpyxl: utils/tests/test_cell.py::test_coordinates
    @Test func coordinates() {
        let r = CellRef("ZF46")
        #expect(r?.columnName == "ZF" && r?.row == 45)
    }

    // openpyxl: utils/tests/test_cell.py::test_invalid_coordinate
    @Test(arguments: ["AAA", "AQ0"]) func invalidCoordinate(_ value: String) {
        #expect(CellRef(value) == nil)
    }

    // openpyxl: utils/tests/test_cell.py::test_absolute
    @Test(arguments: [("ZF51", "$ZF$51"), ("ZF51:ZF53", "$ZF$51:$ZF$53"), ("A:G", "$A:$G"), ("A", "$A"), ("1", "$1")])
    func absolute(_ coord: String, _ result: String) {
        #expect(CellRef.absolute(coord) == result)
    }

    // openpyxl: utils/tests/test_cell.py::test_column_interval
    @Test func columnInterval() {
        let expected = ["A", "B", "C", "D"]
        #expect(CellRef.columnNames(from: "A", to: "D") == expected)
        #expect(CellRef.columnNames(from: 0, to: 3) == expected)
    }

    // openpyxl: utils/tests/test_cell.py::test_column_index
    @Test(arguments: [("j", 9), ("Jj", 269), ("JJj", 7029), ("A", 0), ("Z", 25), ("AA", 26), ("AZ", 51), ("BA", 52), ("BZ", 77), ("ZA", 676),
                      ("ZZ", 701), ("AAA", 702), ("AAZ", 727), ("ABC", 730), ("AZA", 1352), ("ZZA", 18252), ("ZZZ", 18277)])
    func columnIndex(_ column: String, _ idx: Int) {
        #expect(CellRef.columnIndex(column) == idx)
    }

    // openpyxl: utils/tests/test_cell.py::test_bad_column_index
    @Test(arguments: ["JJJJ", "", "$", "1"]) func badColumnIndex(_ column: String) {
        #expect(CellRef.columnIndex(column) == nil)
    }

    // openpyxl: utils/tests/test_cell.py::test_column_letter_boundries
    @Test(arguments: [-1, 18728]) func columnLetterBoundaries(_ value: Int) {
        #expect(CellRef.columnName(validating: value) == nil)
    }

    // openpyxl: utils/tests/test_cell.py::test_column_letter
    @Test(arguments: [(18277, "ZZZ"), (7029, "JJJ"), (27, "AB"), (26, "AA"), (25, "Z")]) func columnLetter(_ value: Int, _ expected: String) {
        #expect(CellRef.columnName(value) == expected)
        #expect(CellRef.columnName(validating: value) == expected)
    }

    // openpyxl: utils/tests/test_cell.py::test_coordinate_tuple
    @Test func coordinateTuple() {
        let r = CellRef("D15")!
        #expect((r.row, r.col) == (14, 3))
    }

    static let rangeToTupleCases: [(String, String, [Int])] = [("Sheet1!$A$1:$A$12", "Sheet1", [0, 0, 0, 11]), ("'My Sheet'!A1:E6", "My Sheet", [0, 0, 4, 5]), ("'E,F'!$A$1:$B$3", "E,F", [0, 0, 1, 2])]
    // openpyxl: utils/tests/test_cell.py::test_range_to_tuple
    @Test(arguments: rangeToTupleCases)
    func rangeToTuple(_ rangeString: String, _ sheetname: String, _ boundaries: [Int]) {
        let r = CellRange(rangeString)
        #expect(r?.sheet == sheetname)
        #expect(r.map { [$0.minCol, $0.minRow, $0.maxCol, $0.maxRow] } == boundaries)
    }

    // openpyxl: utils/tests/test_cell.py::test_invalid_range
    @Test func invalidRange() {
        #expect(CellRange.splitSheetName("A1:E5") == nil)   // range_to_tuple requires a sheet name
    }

    // openpyxl: utils/tests/test_cell.py::test_quote_sheetname
    @Test(arguments: [("In Dusseldorf", "'In Dusseldorf'"), ("My-Sheet", "'My-Sheet'"), ("Demande d'autorisation", "'Demande d''autorisation'"),
                      ("1sheet", "'1sheet'"), (".sheet", "'.sheet'"), ("\"", "'\"'")])
    func quoteSheetname(_ title: String, _ quoted: String) {
        #expect(CellRef.quoteSheetName(title) == quoted)
    }

    // openpyxl: utils/tests/test_cell.py::test_rows_from_range
    @Test func rowsFromRange() {
        let rows = CellRange("A1:D4")!.rows.map { $0.map(\.a1) }
        #expect(rows == [["A1", "B1", "C1", "D1"], ["A2", "B2", "C2", "D2"], ["A3", "B3", "C3", "D3"], ["A4", "B4", "C4", "D4"]])
    }

    // openpyxl: utils/tests/test_cell.py::test_cols_from_range
    @Test func colsFromRange() {
        let cols = CellRange("A1:D4")!.cols.map { $0.map(\.a1) }
        #expect(cols == [["A1", "A2", "A3", "A4"], ["B1", "B2", "B3", "B4"], ["C1", "C2", "C3", "C4"], ["D1", "D2", "D3", "D4"]])
    }

    static let boundsCases: [(String, RangeBounds)] = [
        ("C1:C4", RangeBounds(minCol: 2, minRow: 0, maxCol: 2, maxRow: 3)), ("C1", RangeBounds(minCol: 2, minRow: 0, maxCol: 2, maxRow: 0)),
        ("D:F", RangeBounds(minCol: 3, maxCol: 5)), ("A", RangeBounds(minCol: 0, maxCol: 0)),
        ("1:10", RangeBounds(minRow: 0, maxRow: 9)), ("1", RangeBounds(minRow: 0, maxRow: 0)),
    ]
    // openpyxl: utils/tests/test_cell.py::test_bounds
    @Test(arguments: boundsCases)
    func bounds(_ rangeString: String, _ coords: RangeBounds) {
        #expect(RangeBounds(rangeString) == coords)
    }

    // openpyxl: utils/tests/test_cell.py::test_invalid_bounds
    @Test(arguments: [":", "A:", "1:", ":B", ":2", "A1:", ":B2", "A:2", "1:B", "1:B2", "A:B2", "A1:2", "A1:B"])
    func invalidBounds(_ rangeString: String) {
        #expect(RangeBounds(rangeString) == nil)
    }
}

@Suite struct UtilsDatetimeParityTests {
    static func dt(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0, micro: Int = 0) -> CellValue {
        .date(CivilDateTime(date: CivilDate(year: y, month: m, day: d)!, time: TimeOfDay(hour: h, minute: mi, second: s, nanosecond: micro * 1000)))
    }
    static func time(_ h: Int, _ m: Int, _ s: Int = 0, micro: Int = 0) -> CellValue { .time(TimeOfDay(hour: h, minute: m, second: s, nanosecond: micro * 1000)) }

    static let toISOCases: [(CellValue, String)] = [(dt(2013, 7, 15, 6, 52, 33), "2013-07-15T06:52:33"), (dt(2013, 7, 15, 6, 52, 33, micro: 123456), "2013-07-15T06:52:33.123"),
                                                   (dt(2013, 7, 15), "2013-07-15"), (time(0, 1, 42), "00:01:42"), (time(0, 1, 42, micro: 123456), "00:01:42.123")]
    // openpyxl: utils/tests/test_datetime.py::test_to_iso
    @Test(arguments: toISOCases)
    func toISO(_ value: CellValue, _ expected: String) {
        #expect(ExcelDate.toISO8601(value) == expected)
    }

    // openpyxl: utils/tests/test_datetime.py::test_iso_regex
    @Test(arguments: [("2011-06-30", "date"), ("12:19", "time"), ("12:19:01", "time"), ("12:19:01.123", "time"), ("12:19:01.2", "time")])
    func isoRegex(_ value: String, _ group: String) {
        let parsed = ExcelDate.fromISO8601(value)
        #expect(parsed?.dataType == "d")
        if group == "date" { #expect(parsed?.dateValue != nil) } else { if case .time? = parsed {} else { Issue.record("expected a time for \(value)") } }
    }

    static let fromISOCases: [(String, CellValue)] = [
        ("2011-06-30T13:35:26Z", dt(2011, 6, 30, 13, 35, 26)), ("2013-03-04T12:19:01.00Z", dt(2013, 3, 4, 12, 19, 1)),
        ("2011-06-30", dt(2011, 6, 30)), ("12:19", time(12, 19)), ("12:19:01", time(12, 19, 1)), ("12:19:01.123", time(12, 19, 1, micro: 123_000)),
        ("12:19:01.2", time(12, 19, 1, micro: 200_000)), ("2020-12-03T12:19:01.300Z", dt(2020, 12, 3, 12, 19, 1, micro: 300_000)),
        ("2020-12-03T12:19:01.030", dt(2020, 12, 3, 12, 19, 1, micro: 30_000)), ("2020-12-03T12:19:01.003Z", dt(2020, 12, 3, 12, 19, 1, micro: 3000)),
        ("2020-12-03T12:19:01.3Z", dt(2020, 12, 3, 12, 19, 1, micro: 300_000)), ("2020-12-03T12:19:01.03", dt(2020, 12, 3, 12, 19, 1, micro: 30_000)),
        ("PT0M", .duration(.zero)), ("PT2H0M1S", .duration(.seconds(2 * 3600 + 1))), ("PT25H20M1.1S", .duration(.milliseconds(25 * 3_600_000 + 20 * 60_000 + 1100))),
        ("PT25H70M1.123S", .duration(.milliseconds(25 * 3_600_000 + 70 * 60_000 + 1123))),
    ]
    // openpyxl: utils/tests/test_datetime.py::test_from_iso
    @Test(arguments: fromISOCases)
    func fromISO(_ value: String, _ expected: CellValue) {
        #expect(ExcelDate.fromISO8601(value) == expected)
    }

    static let toExcelCases: [(CellValue, Double)] = [
        (dt(1899, 12, 31), 0), (dt(1900, 1, 1), 1), (dt(1900, 1, 15), 15), (dt(1900, 2, 28), 59), (dt(1900, 2, 28, 21, 0, 0), 59.875), (dt(1900, 3, 1), 61),
        (dt(2010, 1, 18, 14, 15, 20, micro: 1600), 40196.5939815), (dt(2009, 12, 20), 40167), (dt(1506, 10, 15), -143617), (dt(1, 1, 1), -693593),
        (time(0, 0), 0), (time(6, 0), 0.25), (.duration(.seconds(6 * 3600)), 0.25), (.duration(.seconds(-6 * 3600)), -0.25),
    ]
    // openpyxl: utils/tests/test_datetime.py::test_to_excel
    @Test(arguments: toExcelCases)
    func toExcel(_ value: CellValue, _ expected: Double) {
        #expect(abs(ExcelDate.toSerial(value)! - expected) < 1e-7)
    }

    static let toExcelMacCases: [(CellValue, Double)] = [
        (dt(1904, 1, 1), 0), (dt(2011, 10, 31), 39385), (dt(2010, 1, 18, 14, 15, 20, micro: 1600), 38734.5939815), (dt(2009, 12, 20), 38705),
        (dt(1506, 10, 15), -145079), (dt(1, 1, 1), -695055), (time(0, 0), 0), (time(6, 0), 0.25), (.duration(.seconds(6 * 3600)), 0.25), (.duration(.seconds(-6 * 3600)), -0.25),
    ]
    // openpyxl: utils/tests/test_datetime.py::test_to_excel_mac
    @Test(arguments: toExcelMacCases)
    func toExcelMac(_ value: CellValue, _ expected: Double) {
        #expect(abs(ExcelDate.toSerial(value, epoch: .mac1904)! - expected) < 1e-7)
    }

    static let fromExcelCases: [(Double, CellValue)] = [
        (40167, dt(2009, 12, 20)), (21980, dt(1960, 3, 5)), (59, dt(1900, 2, 28)), (-25063, dt(1831, 5, 18)), (59.875, dt(1900, 2, 28, 21, 0, 0)),
        (60, dt(1900, 2, 28)), (60.5, dt(1900, 2, 28, 12, 0)), (61, dt(1900, 3, 1)), (40372.27616898148, dt(2010, 7, 13, 6, 37, 41)),
        (40196.5939815, dt(2010, 1, 18, 14, 15, 20, micro: 2000)), (0.125, time(3, 0)), (42126.958333333219, dt(2015, 5, 2, 23, 0, 0)),
        (42126.999999999884, dt(2015, 5, 3, 0, 0, 0)), (0, time(0, 0)), (0.9999999995, dt(1900, 1, 1)), (1, dt(1900, 1, 1)), (-0.25, dt(1899, 12, 29, 18, 0, 0)),
    ]
    // openpyxl: utils/tests/test_datetime.py::test_from_excel
    @Test(arguments: fromExcelCases)
    func fromExcel(_ value: Double, _ expected: CellValue) {
        #expect(ExcelDate.fromSerial(value) == expected)
    }

    static let fromExcelTimedeltaCases: [(Double, Duration)] = [
        (0, .zero), (0.5, .seconds(12 * 3600)), (-0.5, .seconds(-12 * 3600)), (1.25, .seconds(30 * 3600)), (-1.25, .seconds(-30 * 3600)),
        (0.0006944443, .seconds(60)), (-0.0006944443, .seconds(-60)), (0.0006944328, .milliseconds(59_999)), (-0.0006944328, .milliseconds(-59_999)),
        (59.5, .seconds(59 * 86400 + 12 * 3600)), (60.5, .seconds(60 * 86400 + 12 * 3600)), (61.5, .seconds(61 * 86400 + 12 * 3600)),
        (0.9999999995, .seconds(86400)), (1.0000000005, .seconds(86400)), (1.0000026378, .milliseconds(86_400_228)),
    ]
    // openpyxl: utils/tests/test_datetime.py::test_from_excel_timedelta
    @Test(arguments: fromExcelTimedeltaCases)
    func fromExcelTimedelta(_ value: Double, _ expected: Duration) {
        #expect(ExcelDate.durationFromSerial(value) == expected)
    }

    static let fromExcelMacCases: [(Double, CellValue)] = [(39385, dt(2011, 10, 31)), (21980, dt(1964, 3, 6)), (0, time(0, 0)), (-25063, dt(1835, 5, 19)), (0.75, time(18, 0)), (-0.25, dt(1903, 12, 31, 18, 0, 0))]
    // openpyxl: utils/tests/test_datetime.py::test_from_excel_mac
    @Test(arguments: fromExcelMacCases)
    func fromExcelMac(_ value: Double, _ expected: CellValue) {
        #expect(ExcelDate.fromSerial(value, epoch: .mac1904) == expected)
    }

    static let timeToDaysCases: [(CellValue, Double)] = [(time(13, 55, 12, micro: 36), 0.5800000004166667), (time(3, 0, 0), 0.125), (dt(2021, 3, 19, 13, 55, 12, micro: 36), 0.5800000004166667), (dt(1536, 12, 24, 3, 0, 0), 0.125)]
    // openpyxl: utils/tests/test_datetime.py::test_time_to_days
    @Test(arguments: timeToDaysCases)
    func timeToDays(_ value: CellValue, _ expected: Double) {
        let fraction: Double
        switch value { case .time(let t): fraction = t.dayFraction; case .date(let d): fraction = d.time.dayFraction; default: fraction = -1 }
        #expect(abs(fraction - expected) < 1e-12)
    }

    // openpyxl: utils/tests/test_datetime.py::test_timedelta_to_days
    @Test func timedeltaToDays() {
        #expect(ExcelDate.toSerial(Duration.seconds(86400 + 3 * 3600)) == 1.125)
    }

    // openpyxl: utils/tests/test_datetime.py::test_days_to_time
    @Test func daysToTime() {
        let seconds = 51320.0016   // timedelta(0, 51320, 1600)
        #expect(TimeOfDay(dayFraction: seconds / 86400) == TimeOfDay(hour: 14, minute: 15, second: 20, nanosecond: 2_000_000))   // rounded to the millisecond
    }
}

@Suite struct UtilsEscapeParityTests {
    // openpyxl: utils/tests/test_escape.py::test_escape
    @Test func escape() {
        #expect(OOXMLEscape.escape("My name is \nNewline\r") == "My name is _x000a_Newline_x000d_")
    }

    // openpyxl: utils/tests/test_escape.py::test_unescape
    @Test func unescape() {
        #expect(OOXMLEscape.unescape("My name is _x000a_Newline_x000d_") == "My name is \nNewline\r")
    }
}

@Suite struct UtilsUnitsParityTests {
    // openpyxl: utils/tests/test_units.py::test_dxa_to_inch
    @Test(arguments: [(-120.0, -0.08333333333333334), (0, 0), (240, 0.16666666666666669), (1440, 1), (5000, 3.4722222222222223)])
    func dxaToInch(_ value: Double, _ expected: Double) { #expect(abs(Units.dxaToInch(value) - expected) < 1e-12) }

    // openpyxl: utils/tests/test_units.py::test_inch_to_dxa
    @Test(arguments: [(-10.0, -14400), (0, 0), (1, 1440), (2.37, 3412), (9, 12960)])
    func inchToDxa(_ value: Double, _ expected: Int) { #expect(Units.inchToDxa(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_dxa_to_cm
    @Test(arguments: [(-120.0, -0.2116666666666667), (0, 0), (240, 0.4233333333333334), (1440, 2.54), (5000, 8.819444444444445)])
    func dxaToCm(_ value: Double, _ expected: Double) { #expect(abs(Units.dxaToCm(value) - expected) < 1e-12) }

    // openpyxl: utils/tests/test_units.py::test_cm_to_dxa
    @Test(arguments: [(-10.0, -5669), (0, 0), (1, 566), (10.0, 5669), (1000, 566929)])
    func cmToDxa(_ value: Double, _ expected: Int) { #expect(Units.cmToDxa(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_pixels_to_EMU
    @Test(arguments: [(-10.0, -95250), (0, 0), (1, 9525), (10.0, 95250), (1000, 9525000)])
    func pixelsToEMU(_ value: Double, _ expected: Int) { #expect(Units.pixelsToEMU(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_EMU_to_pixels
    @Test(arguments: [(0.0, 0), (1000, 0), (5000, 1), (9525, 1)])
    func emuToPixels(_ value: Double, _ expected: Int) { #expect(Units.emuToPixels(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_EMU_to_cm
    @Test(arguments: [(-100000.0, -0.2778), (0, 0), (200000, 0.5556), (360000, 1), (500000, 1.3889)])
    func emuToCm(_ value: Double, _ expected: Double) { #expect(Units.emuToCm(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_cm_to_EMU
    @Test(arguments: [(-10.0, -3600000), (0, 0), (1, 360000), (3.23, 1162800)])
    func cmToEMU(_ value: Double, _ expected: Int) { #expect(Units.cmToEMU(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_EMU_to_inch
    @Test(arguments: [(-100000.0, -0.1094), (0, 0), (200000, 0.2187), (914400, 1), (500000, 0.5468)])
    func emuToInch(_ value: Double, _ expected: Double) { #expect(Units.emuToInch(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_inch_to_EMU
    @Test(arguments: [(-10.0, -9144000), (0, 0), (1, 914400), (3.23, 2953512)])
    func inchToEMU(_ value: Double, _ expected: Int) { #expect(Units.inchToEMU(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_pixels_to_points
    @Test(arguments: [(-10.0, -7.5), (0, 0), (1, 0.75), (96, 72), (144, 108)])
    func pixelsToPoints(_ value: Double, _ expected: Double) { #expect(Units.pixelsToPoints(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_points_to_pixels
    @Test(arguments: [(-10.0, -13), (0, 0), (1, 2), (10.0, 14), (72, 96)])
    func pointsToPixels(_ value: Double, _ expected: Int) { #expect(Units.pointsToPixels(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_degrees_to_angle
    @Test(arguments: [(-10.0, -600000), (0, 0), (1, 60000), (10.0, 600000), (1000, 60000000)])
    func degreesToAngle(_ value: Double, _ expected: Int) { #expect(Units.degreesToAngle(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_angle_to_degrees
    @Test(arguments: [(-10.0, 0), (0, 0), (10, 0), (50000, 0.83), (60000, 1)])
    func angleToDegrees(_ value: Double, _ expected: Double) { #expect(Units.angleToDegrees(value) == expected) }

    // openpyxl: utils/tests/test_units.py::test_short_color
    @Test(arguments: [("#FFFFF", "#FFFFF"), ("FF000000", "000000"), ("FFFF0000", "FF0000"), ("FF800000", "800000"), ("FFFFFF00", "FFFF00"), ("FF808000", "808000")])
    func shortColor(_ value: String, _ expected: String) { #expect(Units.shortColor(value) == expected) }
}
