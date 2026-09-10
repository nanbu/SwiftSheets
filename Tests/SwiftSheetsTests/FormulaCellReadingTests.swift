import Testing
import Foundation
@testable import SwiftSheets

/// How a formula cell is read is one choice with two answers, and it means the same thing in every reader
/// (spec Appendix B.54): `.formulas` hands over the formula with its computed value beside it, `.cachedValues` hands
/// over that value alone — and a formula the file never computed reads as an empty cell, never as the formula text.
struct FormulaCellReadingTests {
    private func workbook() -> Workbook {
        var wb = Workbook()
        wb.sheets[0]["A1"] = .formula(FormulaExpr.parse("=1+2"), cached: .integer(3))
        wb.sheets[0]["A2"] = .formula(FormulaExpr.parse("=1+2"), cached: nil)     // never calculated
        return wb
    }

    @Test(arguments: [SheetFormat.xlsx, .ods])
    func wholeWorkbookReadAnswersTheSameInEveryFormat(_ format: SheetFormat) throws {
        let data = try workbook().write(as: format).data
        let formulas = try Workbook(data: data, options: ReadOptions(formulaCells: .formulas))
        #expect(formulas.formulaCells == .formulas)
        #expect(formulas.sheets[0]["A1"]?.formula != nil, "\(format): the default keeps the formula")
        #expect(formulas.sheets[0]["A1"]?.cachedValue == .integer(3), "\(format): with its computed value beside it")
        #expect(formulas.sheets[0]["A2"]?.formula != nil, "\(format): an uncomputed formula is still a formula")

        let values = try Workbook(data: data, options: ReadOptions(formulaCells: .cachedValues))
        #expect(values.formulaCells == .cachedValues)
        #expect(values.sheets[0]["A1"] == .integer(3), "\(format): .cachedValues gives the plain value")
        #expect(values.sheets[0]["A2"] == nil, "\(format): a formula the file never computed reads as empty")
    }

    @Test(arguments: [SheetFormat.xlsx, .ods])
    func rowByRowReadAnswersTheSame(_ format: SheetFormat) throws {
        let data = try workbook().write(as: format).data
        let reader = try StreamingReader(data: data)
        var formulas: [Int: CellValue?] = [:], values: [Int: CellValue?] = [:]
        try reader.forEachRow(inSheet: "Sheet1") { formulas[$0.index] = $0.cells.first?.value }
        try reader.forEachRow(inSheet: "Sheet1", options: StreamingReadOptions(formulaCells: .cachedValues)) { values[$0.index] = $0.cells.first?.value }
        #expect(formulas[1]??.formula != nil && formulas[2]??.formula != nil, "\(format): the default keeps both formulas")
        #expect(values[1] == .integer(3), "\(format): .cachedValues gives the plain value")
        #expect(values[2] ?? nil == nil, "\(format): a formula the file never computed reads as empty")
    }

    /// The default is spelled out, so that a caller who never touches the option gets formulas.
    @Test func theDefaultIsFormulas() {
        #expect(ReadOptions().formulaCells == .formulas)
        #expect(StreamingReadOptions().formulaCells == .formulas)
        #expect(Workbook().formulaCells == .formulas)
    }
}
