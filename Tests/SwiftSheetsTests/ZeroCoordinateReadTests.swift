import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// Spec Appendix B.92. Since B.61 a write to row 0 or column 0 stopped, but a read answered "nothing": a `- 1` left over
/// from the 0-based numbering read an empty cell, `CellRef.columnName(0)` put `$$2:$$4` into a formula, and a test that
/// compared two empty values passed. A read of a number below 1 now stops the way the write does.
///
/// The stops are checked in their own process (`processExitsWith:`), since a `preconditionFailure` takes the process with it.
@Suite struct ZeroCoordinateReadTests {
    @Test func readingACellAtRowOrColumnZeroStops() async {
        await #expect(processExitsWith: .failure) { let wb = Workbook(); _ = wb.sheets[0][0, 1] }
        await #expect(processExitsWith: .failure) { let wb = Workbook(); _ = wb.sheets[0][1, 0] }
        await #expect(processExitsWith: .failure) { let wb = Workbook(); _ = wb.sheets[0][CellRef(row: 0, column: 1)] }
        await #expect(processExitsWith: .failure) { let wb = Workbook(); _ = wb.sheets[0].cell(CellRef(row: 1, column: 0)) }
        await #expect(processExitsWith: .failure) { let wb = Workbook(); _ = wb.sheets[0].table[-1, 1] }
    }

    @Test func dimensionsAtRowOrColumnZeroStop() async {
        await #expect(processExitsWith: .failure) { let wb = Workbook(); _ = wb.sheets[0].rowDimension(0) }
        await #expect(processExitsWith: .failure) { let wb = Workbook(); _ = wb.sheets[0].columnDimension(0) }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].setWidth(10, ofColumn: 0) }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].setHeight(10, ofRow: 0) }
    }

    @Test func aColumnNameBelowOneStops() async {
        await #expect(processExitsWith: .failure) { _ = CellRef.columnName(0) }
        await #expect(processExitsWith: .failure) { _ = CellRef.columnName(-3) }
    }

    /// What answered before still answers: text that does not parse, the validating form, the first real row and
    /// column, and an invalid reference printed in a message.
    @Test func theReadsThatAnswerStillAnswer() {
        let wb = Workbook()
        #expect(wb.sheets[0]["A0"] == nil)
        #expect(wb.sheets[0][1, 1] == nil)
        #expect(wb.sheets[0].rowDimension(1) == RowDimension())
        #expect(CellRef.columnName(validating: 0) == nil)
        #expect(CellRef.columnName(1) == "A")
        #expect(CellRef(row: 0, column: 0).address == "0")
        #expect(CellRange(minRow: 0, minColumn: 0, maxRow: 1, maxColumn: 1).address == "0:A1")
    }
}
