import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// Appendix B.111: Excel's input spellings become its stored formula AST without changing the public enum.
@Suite struct DynamicArrayFormulaSyntaxTests {
    @Test(arguments: ["A1#", "$A$1#", "Sheet2!B3#", "'Other Sheet'!$C4#"])
    func spillSyntaxUsesTheStoredCall(_ input: String) throws {
        let anchorText = String(input.dropLast())
        let anchor = try FormulaExpr.parseStrict(anchorText)
        let spill = try FormulaExpr.parseStrict(input)
        #expect(spill == .call(name: "_xlfn.ANCHORARRAY", args: [anchor]))
        #expect(spill.references == [anchor])
        #expect(spill.rendered(as: .xlsx) == "_xlfn.ANCHORARRAY(" + anchorText + ")")
        #expect(FormulaExpr.parse(spill.rendered(as: .xlsx)) == spill)
        #expect(!spill.isExpressible(in: .ods))
    }

    @Test func spillReferencesFollowSheetAndWorkbookEdits() {
        var workbook = Workbook()
        workbook.addSheet(named: "Other")
        workbook.sheets[1]["D1"] = .formula("SUM(Sheet1!$A$2#)+B2#")
        workbook.insertRows(inSheet: "Sheet1", at: 2, count: 3)
        workbook.renameSheet("Sheet1", to: "Source Data")
        #expect(workbook.sheets[1]["D1"]?.formula?.referencedSheets == ["Source Data"])
        #expect(workbook.sheets[1]["D1"]?.formula?.rendered(as: .xlsx)
                == "SUM(_xlfn.ANCHORARRAY('Source Data'!$A$5))+_xlfn.ANCHORARRAY(B2)")
        workbook.sheets[1].insertColumns(at: 2, count: 1)
        #expect(workbook.sheets[1]["E1"]?.formula?.rendered(as: .xlsx)
                == "SUM(_xlfn.ANCHORARRAY('Source Data'!$A$5))+_xlfn.ANCHORARRAY(C2)")
        workbook.deleteRows(inSheet: "Source Data", at: 5, count: 1)
        #expect(workbook.sheets[1]["E1"]?.formula?.rendered(as: .xlsx)
                == "SUM(_xlfn.ANCHORARRAY(#REF!))+_xlfn.ANCHORARRAY(C2)")
        let range = FormulaExpr.parse("Sheet2!A1#:B2#")
        #expect(range.referencedSheets == ["Sheet2"])
        #expect(range.references == [.ref(CellRef("A1")!, sheet: "Sheet2"), .ref(CellRef("B2")!, sheet: "Sheet2")])
        let shifted = range.shiftingReferences(axis: .rows, at: 1, delta: 2, onSheet: { $0 == "Sheet2" })
        #expect(shifted.rendered(as: .xlsx) == "_xlfn.ANCHORARRAY(Sheet2!A3):_xlfn.ANCHORARRAY(Sheet2!B4)")
        #expect(FormulaExpr.parse(shifted.rendered(as: .xlsx)) == shifted)
    }

    @Test func spillSuffixDoesNotConfuseErrorLiteralsOrOperators() throws {
        let formula = try FormulaExpr.parseStrict("SUM(A1#)+#SPILL!+B2# C3:D4")
        #expect(formula.rendered(as: .xlsx)
                == "SUM(_xlfn.ANCHORARRAY(A1))+#SPILL!+_xlfn.ANCHORARRAY(B2) C3:D4")
        #expect(FormulaExpr.parse(formula.rendered(as: .xlsx)) == formula)
        #expect(throws: SheetError.self) { try FormulaExpr.parseStrict("A1##") }
        #expect(throws: SheetError.self) { try FormulaExpr.parseStrict("1#") }
        #expect(throws: SheetError.self) { try FormulaExpr.parseStrict("of:=[.A1]#", dialect: .ods) }
        #expect(FormulaExpr.parse("#REF!") == .error("#REF!"))
    }

    static let names: [(input: String, stored: String)] = [
        ("FILTER", "_xlfn._xlws.FILTER"), ("SORT", "_xlfn._xlws.SORT"),
        ("SORTBY", "_xlfn.SORTBY"), ("UNIQUE", "_xlfn.UNIQUE"), ("SEQUENCE", "_xlfn.SEQUENCE"),
        ("RANDARRAY", "_xlfn.RANDARRAY"), ("XLOOKUP", "_xlfn.XLOOKUP"), ("XMATCH", "_xlfn.XMATCH"),
        ("ANCHORARRAY", "_xlfn.ANCHORARRAY"),
    ]

    @Test(arguments: names) func inputAndStoredNamesShareOneTree(_ inputName: String, _ storedName: String) throws {
        let input = try FormulaExpr.parseStrict(inputName.lowercased() + "(A1)")
        let stored = try FormulaExpr.parseStrict(storedName + "(A1)")
        #expect(input == stored)
        #expect(input.rendered(as: .xlsx) == storedName + "(A1)")
        #expect(FormulaExpr.call(name: inputName, args: [.ref(CellRef("A1")!)]).rendered(as: .xlsx)
                == storedName + "(A1)")
        #expect(!input.isExpressible(in: .ods))
        #expect(!FormulaExpr.call(name: inputName, args: []).isExpressible(in: .ods))
    }

    @Test func namespaceResolutionLeavesStringsAndUnknownNamespacesAlone() throws {
        let input = "FILTER(A1,A1>0,\"sort(A1) XLOOKUP A1#\")+vendor.SORT(A1)+_xlfn.vendor.FILTER(A1)"
        let formula = try FormulaExpr.parseStrict(input)
        #expect(formula.rendered(as: .xlsx)
                == "_xlfn._xlws.FILTER(A1,A1>0,\"sort(A1) XLOOKUP A1#\")+vendor.SORT(A1)+_xlfn.vendor.FILTER(A1)")
        #expect(FormulaFunctionNames.applicationName("vendor.SORT") == "VENDOR.SORT")
        #expect(FormulaFunctionNames.applicationName("_xlfn.vendor.FILTER") == "_XLFN.VENDOR.FILTER")
    }

    @Test func xlsxWritesStorageNamesAndRereadsTheSameTree() throws {
        var workbook = Workbook()
        let formula = try FormulaExpr.parseStrict("XLOOKUP(1,A1#,SORT(B1:B3))")
        workbook.sheets[0]["D1"] = .formula(formula, cached: .integer(7))
        let written = try workbook.write(as: .xlsx)
        let archive = try ZipInspection(data: written.data)
        let xml = String(decoding: try #require(archive.entry(named: "xl/worksheets/sheet1.xml")), as: UTF8.self)
        #expect(xml.contains("_xlfn.XLOOKUP(1,_xlfn.ANCHORARRAY(A1),_xlfn._xlws.SORT(B1:B3))"))
        #expect(try Workbook(data: written.data).sheets[0]["D1"]?.formula == formula)
    }

    @Test func odsWritesCachedValuesWithCellSpecificWarnings() throws {
        var workbook = Workbook()
        workbook.sheets[0]["D1"] = .formula(FormulaExpr.parse("SUM(A1#)"), cached: .integer(7))
        workbook.sheets[0]["D2"] = .formula(FormulaExpr.parse("FILTER(A1:A3,B1:B3)"), cached: .text("cached"))
        let written = try workbook.write(as: .ods)
        let back = try Workbook(data: written.data)
        #expect(back.sheets[0]["D1"] == .integer(7))
        #expect(back.sheets[0]["D2"] == .text("cached"))
        for address in ["D1", "D2"] {
            #expect(written.warnings.contains {
                $0.kind == .degraded && $0.subject == .formulas && $0.location == CellRef(address)
            })
        }
    }

    @Test(arguments: names.filter { $0.input != "ANCHORARRAY" })
    func numbersUsesItsExistingRegistryForKnownStorageNames(_ inputName: String, _ storedName: String) throws {
        var encoder = NumbersFormulaEncoder(hostTable: "Sheet1::Table1")
        let formula = FormulaExpr.call(name: storedName, args: [.ref(CellRef("A1")!)])
        let encoded = encoder.archive(for: formula, row: 0, column: 1)
        let archive = try #require(encoded)
        let nodes = try #require(archive.message("AST_node_array")).messages("AST_node")
        #expect(nodes.last?.int("AST_function_node_index") == NumbersSchema.shared.functionIndexes[inputName])
        #expect(encoder.problems.isEmpty)
    }

    @Test func numbersCachesSpillReferencesAndDoesNotStripUnknownNamespaces() throws {
        var workbook = Workbook()
        workbook.sheets[0]["D1"] = .formula(FormulaExpr.parse("SUM(A1#)"), cached: .integer(7))
        workbook.sheets[0]["D2"] = .formula(FormulaExpr.parse("vendor.SORT(A1)"), cached: .integer(8))
        let written = try workbook.write(as: .numbers)
        let back = try Workbook(data: written.data)
        #expect(back.sheets[0]["D1"] == .integer(7))
        #expect(back.sheets[0]["D2"] == .integer(8))
        for address in ["D1", "D2"] {
            #expect(written.warnings.contains {
                $0.kind == .degraded && $0.subject == .formulas && $0.location == CellRef(address)
            })
        }
    }
}
