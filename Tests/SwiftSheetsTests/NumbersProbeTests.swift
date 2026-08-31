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

        // The gap the corpus had until 2026-08-31: 05 styles a cell and 09 has two sheets, but nothing put a
        // style on a sheet after the first — and that is the one combination Numbers refuses to open. Written
        // out so the judge says so rather than the corpus staying quiet about it.
        var styleOnSecond = Workbook()
        styleOnSecond.sheets[0]["A1"] = "one"
        styleOnSecond.addSheet(named: "Second")
        styleOnSecond.sheets[1]["A1"] = "two"
        styleOnSecond.sheets[1].style("A1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "FFC7CE")) }
        out.append(("19-style-on-second-sheet", styleOnSecond))

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

        var extras = Workbook()
        var e = extras.sheets[0]
        e["A1"] = "visit example"
        e[cell: "A1"].hyperlink = Hyperlink(target: "https://example.com/one")
        e["B1"] = .richText([TextRun("bold", font: Font(bold: true)), TextRun("plain")])
        e["C1"] = "has a note"
        e[cell: "C1"].comment = CellNote("first note text", author: "Author One")
        extras.sheets[0] = e
        out.append(("13-links-runs-notes", extras))

        var crossTable = Workbook()
        crossTable.sheets[0].name = "Data"
        crossTable.addSheet(named: "Other")
        crossTable.sheets[1]["A1"] = 21
        crossTable.sheets[1]["A2"] = 2
        var x = crossTable.sheets[0]
        x[cell: "D1"].value = .formula(FormulaExpr.parse("Other!A1*2"), cached: nil)
        x[cell: "D2"].value = .formula(FormulaExpr.parse("SUM(Other!A1:A2)"), cached: nil)
        crossTable.sheets[0] = x
        out.append(("14-cross-table", crossTable))

        // everything the format-support table measures, in one document: the sweep the owner asked for
        out.append(("15-kitchen-sink", FormatSupportTests.kitchenSink()))

        var big = Workbook()
        var b = big.sheets[0]
        for r in 0..<300 { b[CellRef(row: r, col: 0)] = .integer(r) }
        big.sheets[0] = b
        out.append(("16-two-tiles", big))

        var popup = Workbook()
        var p = popup.sheets[0]
        p.append([CellValue.text("fruit"), .text("count"), .text("entry")])
        p.append([CellValue.text("apple"), .integer(2)])
        p.dataValidations = [
            .list("\"apple,banana,cherry\"", over: MultiCellRange("A2:A4")!),   // text menu, chosen and empty cells
            .list("\"1,2,3\"", over: MultiCellRange("B2:B4")!),                 // numeric menu
            .list("\"yes,no\"", over: MultiCellRange("C2:C4")!)                 // a menu on nothing but empty cells
        ]
        popup.sheets[0] = p
        out.append(("17-popup-menus", popup))

        var controls = Workbook()
        var q = controls.sheets[0]
        q.append([CellValue.text("kind"), .text("set"), .text("untouched")])
        q.append([CellValue.text("checkbox"), .bool(true)])
        q[cell: "B2"].control = .checkbox
        q[cell: "C2"].control = .checkbox
        q.append([CellValue.text("stepper"), .integer(4)])
        q[cell: "B3"].control = .stepper(minimum: 2, maximum: 8, increment: 2)
        q[cell: "C3"].control = .stepper()
        q.append([CellValue.text("slider"), .integer(30)])
        q[cell: "B4"].control = .slider(minimum: 0, maximum: 60, increment: 5)
        q[cell: "C4"].control = .slider()
        q.append([CellValue.text("rating"), .integer(3)])
        q[cell: "B5"].control = .rating
        q[cell: "C5"].control = .rating
        controls.sheets[0] = q
        out.append(("18-cell-controls", controls))

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
            // the same workbook as Excel, so the sweep can ask Numbers to import it and compare the two paths
            if name.hasSuffix("kitchen-sink") { try wb.write(as: .xlsx).data.write(to: Self.dir.appending(path: "\(name).xlsx")) }
            #expect(try NumbersCodec.read(data).workbook.sheetNames.isEmpty == false, "\(name) is not even readable by us")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: Self.dir.path).count == Self.probes().count + 2)
    }

    /// The other half of the sweep: the document **Numbers itself made from the Excel file**, read by our own
    /// reader rather than by the reference one. `compare_excel_import_with_numbers.py` writes it; the test skips
    /// when it is not there, so a plain `swift test` on a machine without Numbers still passes.
    @Test func readsWhatNumbersMadeFromExcel() throws {
        let url = Self.dir.deletingLastPathComponent().appending(path: "ground/kitchen-sink-by-numbers.numbers")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let result = try NumbersCodec.read(try Data(contentsOf: url))
        // Numbers turns the Excel list validation on B2:B9 into a pop-up menu — the same substitution our writer
        // makes. The reader turns it back into a `.list` rule, so no control warning is expected any more;
        // asserting the rule is the record of what Numbers itself does with a data validation.
        let controls = result.warnings.filter { $0.message.contains("Numbers control") }
        #expect(controls.isEmpty, "\(result.warnings.map(\.message))")
        let rules = result.workbook.sheets["Data"]?.dataValidations ?? []
        #expect(rules.count == 1 && rules.first?.kind == .list, "\(rules)")
        #expect(rules.first?.formula1 == "\"A,B\"")
        // The remaining warnings are about the pivot table Numbers rendered for itself: its cells hold formulas
        // built out of category references and an unnamed spill function, which the model has no word for. The
        // values are kept, and the warning says which cells.
        let unexpected = result.warnings.filter {
            !$0.message.contains("337") && !$0.message.contains("CATEGORY_REF") && !$0.message.contains("could not be decoded")
        }
        #expect(unexpected.isEmpty, "\(unexpected.map(\.message))")
        let wb = result.workbook
        #expect(wb.sheetNames == ["Data", "Pivot", "Hidden", "Multi"], "\(wb.sheetNames)")
        let data = wb.sheets[0]
        #expect(data["A1"] == .text("Region") && data["B1"] == .text("Product"))
        #expect(data["C2"] == .integer(1) && data["D2"] == .number(Decimal(string: "0.5")!))
        #expect(data["H1"] == .text("リンク"), "the Japanese text survives Numbers' own import")
        if case .formula(let expr, _)? = data["F1"] {
            #expect(expr.rendered(as: .xlsx) == "SUM(C2:C9)", "\(expr.rendered(as: .xlsx))")
        } else {
            Issue.record("F1 came back as \(String(describing: data["F1"]))")
        }
        // Numbers renders an imported pivot table as plain cells; we read them as the values they are
        #expect(wb.sheets[1]["A1"] != nil, "the pivot sheet Numbers filled in is not empty")
    }
}
