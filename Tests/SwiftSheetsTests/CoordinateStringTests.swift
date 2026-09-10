import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// Spec Appendix B.53. The model used to answer an unparsable A1 string five different ways: it stopped with a
/// reason, it stopped without one, it returned a default, it did nothing, or it quietly meant something else —
/// `freezePanes(at: "☃")` *released* the freeze. One typo could crash a program at one entry point and silently
/// write nothing at another. The rule is now: **an entry point that changes something stops; one that only reads
/// answers with a default.** Emptiness keeps its own meaning — "" and nil clear, as they always did.
///
/// The stops are checked in their own process (`processExitsWith:`), since a `preconditionFailure` takes the
/// process with it. `☃` is the marker: no coordinate parser in the library accepts it.
@Suite struct CoordinateStringTests {
    static let bad = "☃"

    @Test func noParserAcceptsTheMarker() {
        #expect(CellRef(Self.bad) == nil)
        #expect(CellRange(Self.bad) == nil)
        #expect(CellRef.columnIndex(Self.bad) == nil)
        #expect(MultiCellRange(Self.bad) == nil)
        #expect(RangeBounds(Self.bad) == nil)
    }

    // MARK: - Entry points that change something stop

    @Test func writingCellsStops() async {
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0]["☃"] = 1 }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0][cell: "☃"] = Cell() }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].removeCell("☃") }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].setStyle("☃") { $0.font.bold = true } }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); _ = wb.sheets[0].moveRange("☃", rows: 1) }
    }

    @Test func rangesAndMergesStop() async {
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].merge("☃") }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); _ = wb.sheets[0].unmerge("☃") }
        await #expect(processExitsWith: .failure) { let wb = Workbook(); _ = wb.sheets[0].range("☃") }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); _ = wb.sheets[0].addStructuredTable(named: "t", over: "☃") }
    }

    @Test func columnsAndDimensionsStop() async {
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].setColumnDimension("☃") { $0.width = 10 } }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].setWidth(10, ofColumn: "☃") }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].groupColumns("☃", "C") }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].groupColumns("A", "☃") }
    }

    @Test func sheetFurnitureStops() async {
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].freezePanes(at: "☃") }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].freezePanesA1 = "☃" }
        await #expect(processExitsWith: .failure) { var wb = Workbook(); wb.sheets[0].autoFilterA1 = "☃" }
    }

    /// The print area and the print titles are the exception, and it is not an oversight: they take a defined-name
    /// formula exactly as a file saves it, and the XLSX reader hands them that text. `MySheet!#REF!` is what Excel
    /// leaves behind when the sheet a print area pointed at is deleted, and such a workbook has to open. They stay
    /// lenient — what will not parse is dropped (Appendix B.53, and openpyxl's own test).
    @Test func theFormulaSettersStayLenient() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet.setPrintArea("MySheet!#REF!")
        #expect(sheet.printArea.isEmpty)
        sheet.setPrintArea("Sheet1!$A$1:$E$15,MySheet!#REF!")
        #expect(sheet.printArea == [CellRange("A1:E15")!], "the readable part survives the unreadable one")
        sheet.setPrintTitleRows("☃")
        #expect(sheet.printTitleRows == nil)
        sheet.setPrintTitleColumns("☃")
        #expect(sheet.printTitleColumns == nil)
        sheet.setPrintTitles("'Sheet1'!$1:$2,☃")
        #expect(sheet.printTitleRows == 0...1)
        wb.sheets[0] = sheet
    }

    /// These two stopped before as well — on a bare `CellRef(a1)!`, which says nothing about what was wrong.
    @Test func imagesStopWithAReason() async {
        await #expect(processExitsWith: .failure) {
            var wb = Workbook()
            wb.sheets[0].addImage(try! SheetImage(data: Self.onePixelPNG), at: "☃")
        }
        await #expect(processExitsWith: .failure) {
            var wb = Workbook()
            wb.sheets[0].addImage(try! SheetImage(data: Self.onePixelPNG), over: "☃")
        }
    }

    @Test func addingAConditionalFormatStops() async {
        await #expect(processExitsWith: .failure) {
            var wb = Workbook()
            wb.sheets[0].addConditionalFormatting(ConditionalFormattingRule(kind: .containsBlanks), over: "☃")
        }
    }

    // MARK: - Entry points that only read answer with a default

    @Test func readingNeverStops() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        let sheet = wb.sheets[0]
        #expect(sheet["☃"] == nil)
        #expect(sheet[cell: "☃"] == Cell())
        #expect(sheet.cell("☃") == nil)
        #expect(sheet.style("☃") == .default)
        #expect(sheet.rows(in: "☃").isEmpty)
        #expect(sheet.columns(in: "☃").isEmpty)
        #expect(sheet.values(in: "☃").isEmpty)
        #expect(sheet.column("☃").isEmpty)
        #expect(sheet.isMerged("☃") == false)
        #expect(sheet.columnDimension("☃") == ColumnDimension())
        #expect(sheet.freezePanesA1 == nil && sheet.autoFilterA1 == nil)
    }

    // MARK: - Emptiness still means "clear"

    @Test func emptyAndNilStillClear() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet.freezePanes(at: "B2")
        #expect(sheet.freezePanes != nil)
        sheet.freezePanes(at: "")
        #expect(sheet.freezePanes == nil, "an empty string clears the freeze, as it always did")
        sheet.freezePanes(at: "B2")
        sheet.freezePanes(at: "A1")
        #expect(sheet.freezePanes == nil, "A1 clears it too")
        sheet.freezePanesA1 = "C3"
        sheet.freezePanesA1 = nil
        #expect(sheet.freezePanes == nil)
        sheet.autoFilterA1 = "A1:D10"
        sheet.autoFilterA1 = nil
        #expect(sheet.autoFilter == nil)

        sheet.setPrintArea("A1:B2")
        #expect(sheet.printArea.count == 1)
        sheet.setPrintArea(nil)
        #expect(sheet.printArea.isEmpty)
        wb.sheets[0] = sheet
    }

    /// The answers that were never about a bad string keep their meaning: a move that would go off the sheet is
    /// still nil, and unmerging a range that was not merged is still false.
    @Test func theOtherReasonsForNilAndFalseSurvive() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        #expect(wb.sheets[0].moveRange("A1:B2", rows: -5) == nil, "off the top of the sheet")
        #expect(wb.sheets[0].unmerge("A1:B2") == false, "it was not merged")
        // and the name of a table always comes back now — the Optional only ever meant "unparsable"
        let name: String = wb.sheets[0].addStructuredTable(named: "T", over: "A1:B2")
        #expect(name == "T")
    }

    /// A 1×1 PNG, for the image entry points.
    static let onePixelPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82])
}
