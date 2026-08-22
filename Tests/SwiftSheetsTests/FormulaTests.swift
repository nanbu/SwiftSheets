import Foundation
import Testing
@testable import SheetCore

/// Spec chapter 5: parse → emit → parse is a fixed point; dialects differ only at the edges; references follow edits.
@Suite struct FormulaTests {
    static let fixedPoint: [String] = [
        "SUM(A1:B2,C3)", "-2^2", "2^-1", "A1+B1*2", "(A1+B1)*2", "A1-(B1-C1)", "2^3^2", "IF(A1>1,\"yes\",\"no\")", "Sheet2!A1",
        "'My Sheet'!$A$1:B$2", "A:A", "$1:$3", "SUM(A1,,B1)", "{1,2;3,4}", "TRUE", "#REF!", "1.5", "LOG10(A1)",
        "_xlfn.XLOOKUP(A1,B:B,C:C)", "Table1[Col]", "10%", "-A1%", "(A1,B2)", "\"a\"\"b\"&A1", "SUM(Sheet1!A1:A3)",
        "A1<>B1", "A1<=B1", "A1>=B1", "A1=B1", "MyName*2", "Sheet1!MyName", "-(A1+B1)", "SUM(A1:A3)/COUNT(A1:A3)", "\"\"",
    ]

    @Test(arguments: fixedPoint) func parseEmitParseIsStable(_ text: String) {
        let ast = FormulaExpr.parse(text)
        #expect(!ast.isUnparsed, "\(text)")
        let emitted = ast.rendered(as: .xlsx)
        #expect(FormulaExpr.parse(emitted) == ast, "\(text) → \(emitted)")
        // and the emitted ODS form reads back to the same tree
        #expect(FormulaExpr.parse(ast.rendered(as: .ods), dialect: .ods) == ast, "ods: \(ast.rendered(as: .ods))")
    }

    @Test func unaryMinusBindsTighterThanPower() {
        #expect(FormulaExpr.parse("-2^2") == .binary(.power, .unary(.negate, .number(2)), .number(2)))
        #expect(FormulaExpr.parse("-(2^2)") == .unary(.negate, .binary(.power, .number(2), .number(2))))
        #expect(FormulaExpr.parse("-(2^2)").rendered(as: .xlsx) == "-(2^2)")
    }

    @Test func precedenceAndParentheses() {
        #expect(FormulaExpr.parse("A1+B1*2") == .binary(.add, .ref(CellRef("A1")!), .binary(.multiply, .ref(CellRef("B1")!), .number(2))))
        #expect(FormulaExpr.parse("(A1+B1)*2").rendered(as: .xlsx) == "(A1+B1)*2")
        #expect(FormulaExpr.parse("A1&B1=C1").rendered(as: .xlsx) == "A1&B1=C1")
        #expect(FormulaExpr.parse("2^3^2") == .binary(.power, .binary(.power, .number(2), .number(3)), .number(2)))
    }

    @Test func odsDialect() {
        let ast = FormulaExpr.parse("SUM(A1:B2,C3)")
        #expect(ast.rendered(as: .ods) == "of:=SUM([.A1:.B2];[.C3])")
        #expect(FormulaExpr.parse("of:=SUM([.A1:.B2];[.C3])", dialect: .ods) == ast)
        #expect(FormulaExpr.parse("of:=[$Sheet2.A1]+['My Sheet'.$B$2]", dialect: .ods).rendered(as: .xlsx) == "Sheet2!A1+'My Sheet'!$B$2")
        #expect(FormulaExpr.parse("Sheet2!A1:B2").rendered(as: .ods) == "of:=[Sheet2.A1:.B2]")
    }

    @Test func unparsableTextIsKeptVerbatim() {
        let ast = FormulaExpr.parse("=SUM(A1:B5 B2:C3)")   // the intersection operator is not supported
        #expect(ast == .unparsed("SUM(A1:B5 B2:C3)", dialect: .xlsx))
        #expect(ast.rendered(as: .xlsx) == "SUM(A1:B5 B2:C3)")
        #expect(ast.text == "=SUM(A1:B5 B2:C3)")
        #expect(throws: SheetError.self) { try FormulaExpr.parseStrict("1+") }
    }

    @Test func sheetPrefixAppliesToBothEndpoints() {
        let ast = FormulaExpr.parse("Sheet2!A1:B2")
        #expect(ast == .range(.ref(CellRef("A1")!, sheet: "Sheet2"), .ref(CellRef("B2")!, sheet: "Sheet2")))
        #expect(ast.referencedSheets == ["Sheet2"])
    }

    @Test func functionNamesAreCanonical() {
        #expect(FormulaExpr.parse("sum(a1)").rendered(as: .xlsx) == "SUM(A1)")
        #expect(FormulaExpr.parse("_xlfn.xlookup(A1,B:B,C:C)").rendered(as: .xlsx) == "_xlfn.XLOOKUP(A1,B:B,C:C)")
    }

    @Test func renamingSheets() {
        let ast = FormulaExpr.parse("Old!A1+'Old'!B2:C3+Other!A1+A1")
        let renamed = ast.renamingSheet("Old", to: "New Name")
        #expect(renamed.rendered(as: .xlsx) == "'New Name'!A1+'New Name'!B2:C3+Other!A1+A1")
    }

    @Test func insertingRowsShiftsReferencesBelow() {
        let ast = FormulaExpr.parse("SUM(A1:A5)+B3+$B$1+Other!B3")
        let shifted = ast.shiftingReferences(axis: .rows, at: 2, delta: 2) { $0 == nil }
        #expect(shifted.rendered(as: .xlsx) == "SUM(A1:A7)+B5+$B$1+Other!B3")
    }

    @Test func deletingRowsShrinksRangesAndInvalidatesCells() {
        let ast = FormulaExpr.parse("SUM(A1:A5)+B3+B6")
        let shifted = ast.shiftingReferences(axis: .rows, at: 2, delta: -1) { $0 == nil }
        #expect(shifted.rendered(as: .xlsx) == "SUM(A1:A4)+#REF!+B5")
        let gone = FormulaExpr.parse("SUM(A2:A3)").shiftingReferences(axis: .rows, at: 1, delta: -2) { $0 == nil }
        #expect(gone.rendered(as: .xlsx) == "SUM(#REF!)")
        let cols = FormulaExpr.parse("SUM(B1:D1)+C:C").shiftingReferences(axis: .columns, at: 2, delta: -1) { $0 == nil }
        #expect(cols.rendered(as: .xlsx) == "SUM(B1:C1)+#REF!")
    }

    @Test func sheetOperationsTranslateFormulas() {
        var wb = Workbook()
        wb.addSheet(named: "Other")
        wb.sheets[0]["A1"] = 1
        wb.sheets[0]["A2"] = 2
        wb.sheets[0]["B1"] = Formula("=SUM(A1:A2)+Other!A1")
        wb.sheets[1]["A1"] = Formula("=Sheet1!A2*2")
        wb.sheets[0].insertRows(at: 1, count: 1)   // only this sheet's own references move
        #expect(wb.sheets[0]["B1"]?.formula?.text == "=SUM(A1:A3)+Other!A1")
        #expect(wb.sheets[0]["A3"] == .integer(2))
        #expect(wb.sheets[1]["A1"]?.formula?.text == "=Sheet1!A2*2")
        wb.insertRows(inSheet: "Sheet1", at: 0, count: 1)   // workbook-wide
        #expect(wb.sheets[0]["B2"]?.formula?.text == "=SUM(A2:A4)+Other!A1")
        #expect(wb.sheets[1]["A1"]?.formula?.text == "=Sheet1!A3*2")
        wb.sheets[0].name = "Main"
        #expect(wb.sheets[1]["A1"]?.formula?.text == "=Main!A3*2")
        wb.renameSheet("Other", to: "My Other")
        #expect(wb.sheets[0]["B2"]?.formula?.text == "=SUM(A2:A4)+'My Other'!A1")
    }

    @Test func formulaValuesInCells() {
        var s = Sheet(name: "S")
        s["A1"] = "=SUM(B1:B2)"          // string literal inference, like openpyxl
        s["A2"] = Formula("=A1*2")
        s["A3"] = CellValue(formula: "1+1", cached: .integer(2))
        #expect(s["A1"]?.formula?.text == "=SUM(B1:B2)")
        #expect(s["A2"]?.dataType == "f")
        #expect(s["A3"]?.cachedValue == .integer(2))
        #expect(s["A3"]?.intValue == 2)
        #expect(s["A1"]?.pythonString == "=SUM(B1:B2)")
    }
}
