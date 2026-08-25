import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// Writes the probe corpus the Numbers.app judge walks (`Tests/NumbersParity/verify_with_numbers_app.py`).
///
/// Each probe adds one thing to the one before it, so when Numbers refuses a document the first refusal names the
/// feature that broke it. The files go under `.build/numbers-judge/probes`, which is where the judge stages
/// documents anyway — Numbers is sandboxed and will not read a temporary directory.
@Suite struct NumbersProbeTests {
    static let dir: URL = {
        let url = URL(filePath: #filePath).deletingLastPathComponent()   // …/Tests/SwiftSheetsTests
            .deletingLastPathComponent().deletingLastPathComponent()      // the package
            .appending(path: ".build/numbers-judge/probes")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func probes() -> [(String, Workbook)] {
        var out: [(String, Workbook)] = []
        out.append(("01-empty", Workbook()))

        var text = Workbook(); text.sheets[0]["A1"] = "hello"
        out.append(("02-one-text", text))

        var number = Workbook(); number.sheets[0]["A1"] = 42
        out.append(("03-one-number", number))

        var kinds = Workbook()
        kinds.sheets[0]["A1"] = 1.5
        kinds.sheets[0]["A2"] = true
        kinds.sheets[0]["A3"] = CellValue(CivilDate(year: 2026, month: 9, day: 1)!)
        kinds.sheets[0]["A4"] = CellValue(Duration.seconds(3661))
        out.append(("04-value-kinds", kinds))

        var styled = Workbook()
        styled.sheets[0]["A1"] = "styled"
        styled.sheets[0].style("A1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "FFCC00")) }
        out.append(("05-cell-style", styled))

        var formatted = Workbook()
        formatted.sheets[0]["A1"] = 1234.5
        formatted.sheets[0].style("A1") { $0.numberFormat = "#,##0.00" }
        out.append(("06-number-format", formatted))

        var sized = Workbook()
        sized.sheets[0]["A1"] = "sized"
        sized.sheets[0].setWidth(30, ofColumn: "A"); sized.sheets[0].setHeight(40, ofRow: 0)
        out.append(("07-sizes", sized))

        var merged = Workbook()
        merged.sheets[0]["A1"] = "merged"; merged.sheets[0].merge("A1:B2")
        out.append(("08-merge", merged))

        var twoSheets = Workbook()
        twoSheets.sheets[0]["A1"] = "one"
        twoSheets.addSheet(named: "Second"); twoSheets.sheets[1]["A1"] = "two"
        out.append(("09-two-sheets", twoSheets))

        var twoTables = Workbook()
        var s = twoTables.sheets[0]
        s["A1"] = "first"
        let t = s.addTable(named: "Second", anchor: CellRef("A10")!)
        s.tables[t]["A1"] = "second"
        twoSheets.sheets[0] = s
        twoTables.sheets[0] = s
        out.append(("10-two-tables", twoTables))

        var formula = Workbook()
        formula.sheets[0]["A1"] = 2
        formula.sheets[0][cell: "A2"].value = .formula(FormulaExpr.parse("A1*3"), cached: .integer(6))
        out.append(("11-formula", formula))

        var conditional = Workbook()
        var c = conditional.sheets[0]
        for r in 0..<5 { c[CellRef(row: r, col: 0)] = .integer(r * 7) }
        c.addConditionalFormatting(.cellIs(.greaterThan, "11", paint: .highlight(fill: Color(hex: "FFC7CE")), priority: 1), over: "A1:A5")
        conditional.sheets[0] = c
        out.append(("12-conditional-format", conditional))

        var big = Workbook()
        var b = big.sheets[0]
        for r in 0..<300 { b[CellRef(row: r, col: 0)] = .integer(r) }
        big.sheets[0] = b
        out.append(("13-two-tiles", big))
        return out
    }

    @Test func writesTheProbeCorpus() throws {
        try? FileManager.default.removeItem(at: Self.dir)
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        // the template itself is the control: if Numbers refuses this one, the finding is about the machine
        try FileManager.default.copyItem(at: NumbersCodec.templateURL, to: Self.dir.appending(path: "00-template.numbers"))
        for (name, wb) in Self.probes() {
            let data = try wb.write(as: .numbers).data
            try data.write(to: Self.dir.appending(path: "\(name).numbers"))
            #expect(try NumbersCodec.read(data).workbook.sheetNames.isEmpty == false, "\(name) is not even readable by us")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: Self.dir.path).count == Self.probes().count + 1)
    }
}
