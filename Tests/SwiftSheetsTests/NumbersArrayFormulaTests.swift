import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// Array formulas across the Numbers boundary (spec Appendix B.26). Numbers spreads an array formula the way its
/// own Excel import shows: the anchor cell keeps the formula itself, and every covered cell holds the unnamed
/// spill function — `337(anchor)` — showing its own element of the result. `array-15.numbers` is Numbers 15.3.1's
/// import of an openpyxl workbook holding `=A1:A5*2` over B1:B5, and both directions here copy that shape.
@Suite struct NumbersArrayFormulaTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/numbers/\(name)"))
    }

    // MARK: - Reading Numbers' own document

    @Test func theSpreadComesBackAsOneArrayFormula() throws {
        let result = try NumbersCodec.read(try Self.fixture("array-15.numbers"))
        let table = result.workbook.sheets[0].tables[0]
        #expect(table.arrayFormulas == [CellRef("B1")!: CellRange("B1:B5")!], Comment(rawValue: "\(table.arrayFormulas)"))
        // the anchor keeps the formula, the covered cells their values — the model's own shape for one
        #expect(result.workbook.sheets[0]["B1"]?.formula != nil)
        #expect(result.workbook.sheets[0]["B3"]?.intValue == 6)
        #expect(result.workbook.sheets[0]["B3"]?.formula == nil)
    }

    @Test func spillCellsRaiseNoDecodeWarnings() throws {
        let result = try NumbersCodec.read(try Self.fixture("array-15.numbers"))
        let noise = result.warnings.filter { $0.message.contains("337") || $0.message.contains("could not be decoded") }
        #expect(noise.isEmpty, Comment(rawValue: "\(result.warnings.map(\.message))"))
    }

    // MARK: - Writing

    /// The write side does NOT spread: Numbers' spill function was measured dead under recalculation — even
    /// Numbers' own spread, version-faked old so the load recalculates it, loses its values on open. Every
    /// document written from the old-version template is recalculated, so the covered cells keep their values,
    /// the anchor keeps its formula, and the lost range is named (Appendix B.26).
    @Test func writingKeepsValuesAndNamesTheLostRange() throws {
        var wb = Workbook()
        var s = wb.sheets[0]
        for r in 0..<3 { s[CellRef(row: r, col: 0)] = .integer(r + 1) }
        s[cell: "B1"].value = .formula(FormulaExpr.parse("A1:A3*2"), cached: .integer(2))
        s["B2"] = 4
        s["B3"] = 6
        s.table.arrayFormulas[CellRef("B1")!] = CellRange("B1:B3")!
        wb.sheets[0] = s

        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.message.contains("array formula") && $0.message.contains("recalculation") },
                Comment(rawValue: "\(result.warnings.map(\.message))"))
        let back = try Workbook(data: result.data)
        #expect(back.sheets[0].tables[0].arrayFormulas.isEmpty)      // the range is what is lost…
        #expect(back.sheets[0]["B1"]?.formula != nil)                // …not the formula
        #expect(back.sheets[0]["B2"]?.intValue == 4)                 // …nor the covered values
        #expect(back.sheets[0]["B3"]?.intValue == 6)
    }
}
