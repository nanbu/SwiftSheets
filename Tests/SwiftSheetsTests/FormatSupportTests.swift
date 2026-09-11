import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// The format-support matrix of `docs/format-support.html`, as a test.
///
/// One workbook carries everything the model can say. It is written to each format and read back, and what came
/// home is compared with what went out. The published table is that measurement, so this test is what keeps the
/// table honest: change a codec and the profile below changes with it, or the test says so.
@Suite struct FormatSupportTests {
    /// A workbook that exercises every feature the matrix lists.
    static func kitchenSink() -> Workbook {
        var wb = Workbook()
        wb.metadata.title = "全部入り"
        wb.customProperties["部署"] = .text("経理")
        wb.definedNames["Rate"] = "0.08"
        wb.protection.locksStructure = true

        var d = wb.sheets[0]
        d.name = "Data"
        d.append([CellValue.text("Region"), .text("Product"), .text("Qty"), .text("Price")])
        for i in 0..<8 {
            d.append([CellValue.text(["East", "West", "North"][i % 3]), .text(i.isMultiple(of: 2) ? "A" : "B"),
                      .integer(i + 1), .number(Decimal(i) + Decimal(string: "0.5")!)])
        }
        d["F1"] = .formula("=SUM(C2:C9)")
        // a quote function: only Numbers can recompute one, so only Numbers keeps the formula (Appendix B.27)
        d["F2"] = .formula(FormulaExpr.parse("STOCK(\"AAPL\",0)"), cached: .number(313.45))
        d.table.arrayFormulas[CellRef("G1")!] = CellRange("G1:G8")!
        d["G1"] = .formula("=C2:C9*2")
        d["H1"] = "リンク"
        d[cell: "H1"].hyperlink = Hyperlink(target: "https://example.com/")
        d["H2"] = "メモつき"
        d[cell: "H2"].note = CellNote("これはメモ", author: "作者")
        d["H3"] = .richText([TextRun("赤", font: Font(bold: true)), TextRun("青")])
        d.merge("A11:B12")
        d["A11"] = "結合"
        d.setStyle("A1:D1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "DDEBF7")); $0.alignment.horizontal = .center }
        d.setStyle("D2:D9") { $0.numberFormat = "#,##0.00" }
        d.setWidth(18, ofColumn: 1)
        d.setHeight(24, ofRow: 1)
        d.groupRows(4...6, outlineLevel: 1)
        d.freezePanes = CellRef("A2")
        d.autoFilter = CellRange("A1:D9")
        d.filterColumns = [FilterColumn(columnOffset: 0, values: ["East"])]
        d.sortState = SortState(range: CellRange("A2:D9")!, conditions: [SortCondition(range: CellRange("C2:C9")!, descending: true)])
        d.addStructuredTable(named: "Sales", over: "A1:D9")
        d.dataValidations = [DataValidation.list("\"A,B\"", over: MultiCellRange("B2:B9")!, rejects: true)]
        d["I2"] = true
        d[cell: "I2"].control = .checkbox
        let red = DifferentialStyle.highlight(fill: Color(hex: "FFC7CE"), text: Color(hex: "9C0006"))
        d.addConditionalFormatting(.cellIs(.greaterThan, "5", paint: red, priority: 1), over: "C2:C9")
        d.addConditionalFormatting(.colorScale(.twoColor(from: .white, to: Color(hex: "63BE7B")), priority: 2), over: "D2:D9")
        d.addConditionalFormatting(.dataBar(DataBar(color: Color(hex: "638EC6")), priority: 3), over: "C2:C9")
        d.addConditionalFormatting(.iconSet(.threeBand(), priority: 4), over: "D2:D9")
        d.protection.enabled = true
        d.protectedRanges = [ProtectedRange(name: "open", ranges: MultiCellRange("A2:A9")!)]
        d.scenarios = ScenarioList([Scenario(name: "強気", cells: [Scenario.InputCell("C2", "99")!])])
        d.rowBreaks = [6]
        d.columnBreaks = [3]
        d.headerFooter.oddHeader = "&L社外秘&R&P"
        d.pageSetup.orientation = .landscape
        d.pageSetup.paperSize = 9
        d.printOptions.gridLines = true
        d.printAreaFormula = "A1:D9"
        d.printTitleRows = 1...1
        d.definedNames["Local"] = "$A$1"
        d.tabColor = Color(hex: "FF0000")
        wb.sheets[0] = d

        // what only OpenDocument has (spec Appendix B.17)
        wb.epoch = .mac1904
        wb.calculationSettings.usesRegularExpressions = true
        wb.calculationSettings.nullYear = 1930
        wb.labelRanges = [LabelRange(labels: CellRange("Data!A1:D1")!, data: CellRange("Data!A2:D9")!, orientation: .column)]
        wb.consolidation = Consolidation(function: .sum, sources: [CellRange("Data!A1:D9")!],
                                         target: CellRef("A20")!, targetSheet: "Data", useLabels: .both)
        wb.sheets[0].table.detective[CellRef("F1")!] = CellDetective(
            highlighted: [CellDetective.HighlightedRange(range: CellRange("Data!C2:C9"), direction: .fromSameTable)],
            operations: [CellDetective.Operation(.tracePrecedents, index: 0)])
        wb.sheets[0]["I1"] = .number(Decimal(string: "1234.5")!)
        wb.sheets[0].setStyle("I1") { $0.numberFormat = "[$¥-411]#,##0.00" }

        wb.addSheet(named: "Pivot")
        _ = wb.addPivotTable(named: "Summary", to: "Pivot", at: CellRef("A3")!, summarizing: CellRange("A1:D9")!,
                             on: "Data", rows: ["Region"], columns: ["Product"], values: [("Qty", .sum)])
        wb.addSheet(named: "Hidden")
        wb.sheets[2].isHidden = true
        wb.sheets[2]["A1"] = "隠しシート"
        // several tables on one canvas: only Numbers keeps them
        wb.addSheet(named: "Multi")
        wb.sheets[3]["A1"] = "表1"
        let second = wb.sheets[3].addTable(named: "表2", at: CellRef("D1")!)
        wb.sheets[3].tables[second]["A1"] = "二枚目"
        return wb
    }

    /// The 48 rows of the published table, in its order. Each says whether the feature came home.
    static func profile(of workbook: Workbook) -> [String: Bool] {
        let s = workbook.sheets["Data"] ?? workbook.sheets[0]
        let pivot = workbook.sheets["Pivot"]
        let rules = s.conditionalFormatting.flatMap(\.rules)
        var richText = false
        if case .richText? = s["H3"] { richText = true }
        return [
            "values": s["A2"] == .text("East"),
            "formulas": s["F1"]?.formula != nil,
            "quote functions": s["F2"]?.formula?.remoteDataFunction != nil,
            "array formulas": !s.table.arrayFormulas.isEmpty,
            "merges": s.merges.contains(CellRange("A11:B12")!),
            "bold font": s.style("A1").font.bold,
            "fill": s.style("A1").fill.foregroundColor != nil,
            "alignment": s.style("A1").alignment.horizontal == .center,
            "number format": s.style("D2").numberFormat == "#,##0.00",
            "column width": s.columnDimension(1).width != nil,
            "row height": s.rowDimension(1).height != nil,
            "outline groups": s.rowDimensions.values.contains { $0.outlineLevel > 0 },
            "frozen panes": s.freezePanes != nil,
            "hyperlinks": s.cell("H1")?.hyperlink != nil,
            "notes": s.cell("H2")?.note != nil,
            "rich text": richText,
            "conditional formatting": rules.contains { $0.kind == .cellIs },   // the plain rule; the three richer kinds have rows of their own
            "CF colour scale": rules.contains { $0.kind == .colorScale },
            "CF data bar": rules.contains { $0.kind == .dataBar },
            "CF icon set": rules.contains { $0.kind == .iconSet },
            "data validation": !s.dataValidations.isEmpty,
            "cell controls": s.cell("I2")?.control != nil,
            "structured tables": !s.structuredTables.isEmpty,
            "auto-filter": s.autoFilter != nil,
            "filter criteria": !s.filterColumns.isEmpty,
            "sort state": s.sortState != nil,
            "pivot tables": !(pivot?.pivotTables.isEmpty ?? true),
            "sheet protection": s.protection.enabled,
            "protected ranges": !s.protectedRanges.isEmpty,
            "scenarios": !s.scenarios.isEmpty,
            "print header and footer": !s.headerFooter.isEmpty,
            "print orientation": s.pageSetup.orientation == .landscape,
            "print area": !s.printArea.isEmpty,
            "print title rows": s.printTitleRows != nil,
            "page breaks": !s.rowBreaks.isEmpty,
            "tab colour": s.tabColor != nil,
            "workbook defined names": !workbook.definedNames.isEmpty,
            "sheet defined names": !s.definedNames.isEmpty,
            "workbook protection": workbook.protection.locksStructure,
            "custom properties": !workbook.customProperties.isEmpty,
            "hidden sheets": workbook.sheets.contains { $0.isHidden },
            "several tables per sheet": (workbook.sheets["Multi"]?.tables.count ?? 0) > 1,
            // ODF only (Appendix B.17)
            "label ranges": !workbook.labelRanges.isEmpty,
            "consolidation": workbook.consolidation != nil,
            "detective arrows": !s.tables.allSatisfy(\.detective.isEmpty),
            "calculation settings": workbook.calculationSettings.usesRegularExpressions,
            "date origin": workbook.epoch == .mac1904,
            "currency cell type": s.style("I1").numberFormat.contains("¥"),
        ]
    }

    /// What each format is *expected* to lose. Everything not named here has to survive.
    static let expectedLosses: [SheetFormat: Set<String>] = [
        .xlsx: ["quote functions", "cell controls", "several tables per sheet", "label ranges", "consolidation", "detective arrows", "calculation settings"],
        .ods: ["quote functions", "cell controls", "protected ranges", "scenarios", "several tables per sheet"],
        .numbers: [
            "array formulas", "outline groups",
            "CF colour scale", "CF data bar", "CF icon set",
            "structured tables", "auto-filter", "filter criteria", "sort state", "pivot tables",
            "sheet protection", "protected ranges", "scenarios",
            "print area", "page breaks", "tab colour",
            "workbook defined names", "sheet defined names", "workbook protection", "custom properties", "hidden sheets",
            "label ranges", "consolidation", "detective arrows", "calculation settings",
        ],
    ]

    /// How many warnings each format's write returns for this workbook — the number the published table quotes.
    static let expectedWarningCount: [SheetFormat: Int] = [.xlsx: 7, .ods: 8, .numbers: 24]

    @Test(arguments: [SheetFormat.xlsx, .ods, .numbers])
    func matchesThePublishedTable(_ format: SheetFormat) throws {
        let wb = Self.kitchenSink()
        let result = try wb.write(as: format)
        let back = try Workbook(data: result.data)
        let survived = Self.profile(of: back)
        let expected = Self.expectedLosses[format]!

        let lost = Set(survived.filter { !$0.value }.keys)
        #expect(lost == expected, """
            \(format.rawValue): the format-support table says these are lost — \(expected.sorted())
            but the measurement says — \(lost.sorted())
            (unexpectedly lost: \(lost.subtracting(expected).sorted()); \
            unexpectedly kept: \(expected.subtracting(lost).sorted()))
            docs/format-support.html has to be updated with the code.
            """)
        #expect(survived.count == 48, "the published table has 48 rows")

        // nothing is dropped in silence: every loss is answered by a warning
        #expect(result.warnings.count == Self.expectedWarningCount[format]!,
                "\(format.rawValue): \(result.warnings.count) warning(s) — \(result.warnings.map(\.message))")
        if !expected.isEmpty { #expect(!result.warnings.isEmpty) }
    }

    // MARK: - The published table

    /// The rows of `docs/format-support.html`, in its order, against the profile keys each one stands for.
    /// Four of the published rows carry two features apiece (the page merges what the measurement keeps apart),
    /// which is why 44 rows cover 48 keys.
    static let publishedRows: [(label: String, keys: [String])] = [
        ("Values (number, text, date, boolean, duration, error)", ["values"]),
        ("Formulas", ["formulas"]),
        ("└ Stock and currency functions (STOCK, CURRENCY and four others)", ["quote functions"]),
        ("Array formulas (with their range)", ["array formulas"]),
        ("Formatting within a cell (rich text)", ["rich text"]),
        ("Hyperlinks", ["hyperlinks"]),
        ("Notes (cell comments)", ["notes"]),
        ("Merged cells", ["merges"]),
        ("Cell style (font, bold, colour, borders)", ["bold font"]),
        ("Fill (solid, gradient)", ["fill"]),
        ("Alignment and wrapping", ["alignment"]),
        ("Number format (#,##0.00 and the like)", ["number format"]),
        ("Column width, row height, hidden rows and columns", ["column width", "row height"]),
        ("Row and column grouping (outline)", ["outline groups"]),
        ("Frozen panes", ["frozen panes"]),
        ("Tab colour", ["tab colour"]),
        ("Comparison, formula, text, top/bottom, above/below average, duplicate/unique, blank/error, time period", ["conditional formatting"]),
        ("Colour scale (2- and 3-colour)", ["CF colour scale"]),
        ("Data bar", ["CF data bar"]),
        ("Icon set", ["CF icon set"]),
        ("Data validation (drop-down lists, range checks)", ["data validation"]),
        ("Cell controls (checkbox, stepper, slider, rating)", ["cell controls"]),
        ("Named tables", ["structured tables"]),
        ("AutoFilter (the range)", ["auto-filter"]),
        ("└ Filter criteria and the recorded sort", ["filter criteria", "sort state"]),
        ("Pivot tables", ["pivot tables"]),
        ("Sheet protection", ["sheet protection"]),
        ("Protected ranges (editable windows in a protected sheet)", ["protected ranges"]),
        ("Scenarios", ["scenarios"]),
        ("Header/footer", ["print header and footer"]),
        ("Orientation, paper, scale, margins, centering", ["print orientation"]),
        ("Print area, title rows/columns", ["print area", "print title rows"]),
        ("Page breaks", ["page breaks"]),
        ("Defined names (workbook and sheet)", ["workbook defined names", "sheet defined names"]),
        ("Workbook protection (locking the sheet structure)", ["workbook protection"]),
        ("Custom document properties (department, case number and the like)", ["custom properties"]),
        ("Hidden sheets", ["hidden sheets"]),
        ("Several tables on one sheet", ["several tables per sheet"]),
        ("Label ranges (a heading used as is in a formula)", ["label ranges"]),
        ("Consolidation definitions", ["consolidation"]),
        ("Detective arrows (tracing precedents and dependents)", ["detective arrows"]),
        ("Calculation settings (regular expressions, wildcards, case sensitivity, two-digit years)", ["calculation settings"]),
        ("Date epoch", ["date origin"]),
        ("Currency cell type", ["currency cell type"]),
    ]

    /// The page is the measurement, written out for people. Until this test existed, that was a promise kept by
    /// remembering — and it had already slipped: the page said the kitchen-sink workbook returns 6 warnings for
    /// Excel and 9 for ODS when the measurement says 7 and 10. Now the page cannot drift without going red.
    ///
    /// Two of the three marks carry a fact this measurement owns, and one does not:
    ///
    /// * **○** — came home unchanged. The probe must have found it.
    /// * **×** — did not go through at all. The probe must have missed it.
    /// * **△** — went through in another shape. The probe is binary, so it may say either and be right: a quote
    ///   function written as its cached value *is* a loss to `formula?.remoteDataFunction` and *is* a △ on the
    ///   page. Pinning △ would be pinning the page's editorial judgement, so those cells are left to the page.
    ///
    /// That still leaves the great majority of the cells checked against the code.
    @Test func thePublishedTableSaysWhatTheMeasurementSays() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appending(path: "docs/format-support.html"), encoding: .utf8)

        // the rows of the one table under <h2>The table</h2>
        guard let start = page.range(of: "<h2>The table</h2>"), let end = page.range(of: "</table>", range: start.upperBound..<page.endIndex)
        else { Issue.record("docs/format-support.html has no \"The table\" table"); return }
        var published: [String: [String]] = [:]     // label → the three marks
        for chunk in page[start.upperBound..<end.lowerBound].components(separatedBy: "<tr").dropFirst() {
            let cells = Self.cells(of: chunk)
            guard cells.count >= 4 else { continue }
            let marks = Array(cells[1...3])
            guard marks.allSatisfy({ ["○", "△", "×"].contains($0) }) else { continue }
            published[cells[0]] = marks
        }

        let formats: [SheetFormat] = [.xlsx, .ods, .numbers]
        var covered = Set<String>()
        for (label, keys) in Self.publishedRows {
            guard let marks = published[label] else {
                Issue.record(Comment(rawValue: "the published table has no row \"\(label)\" (it was renamed, or removed)"))
                continue
            }
            for (mark, format) in zip(marks, formats) {
                for key in keys {
                    covered.insert(key)
                    guard mark != "△" else { continue }        // "changed shape": the binary probe cannot judge it
                    let measured = Self.expectedLosses[format]?.contains(key) ?? false
                    #expect((mark == "×") == measured, Comment(rawValue:
                        "docs/format-support.html prints \(mark) for \(format.rawValue) on \"\(label)\" "
                        + "but the measurement says it \(measured ? "does not come home" : "comes home") "
                        + "— update the page with the code"))
                }
            }
        }
        #expect(published.count == Self.publishedRows.count,
                Comment(rawValue: "the page has \(published.count) rows, the mapping names \(Self.publishedRows.count)"))
        #expect(covered.count == 48, "every one of the 48 measured features must appear in the published table")

        // the three scores, and the three warning counts, are arithmetic on the same measurement
        for format in formats {
            let kept = 48 - (Self.expectedLosses[format]?.count ?? 0)
            #expect(page.contains("<div class=\"num\">\(kept)<small> / 48</small></div>"),
                    Comment(rawValue: "the page must show \(kept) / 48 for \(format.rawValue)"))
        }
        let counts = formats.map { Self.expectedWarningCount[$0]! }
        #expect(page.contains("Excel \(counts[0]), ODS \(counts[1]), Numbers \(counts[2])"),
                Comment(rawValue: "the page must say Excel \(counts[0]), ODS \(counts[1]), Numbers \(counts[2])"))
    }

    /// The text of a row's `<td>`s, tags and entities removed — enough to read a label and a mark.
    static func cells(of row: String) -> [String] {
        var out: [String] = []
        var rest = Substring(row)
        while let open = rest.range(of: "<td"), let gt = rest.range(of: ">", range: open.upperBound..<rest.endIndex),
              let close = rest.range(of: "</td>", range: gt.upperBound..<rest.endIndex) {
            var text = ""
            var inTag = false
            for character in rest[gt.upperBound..<close.lowerBound] {
                if character == "<" { inTag = true } else if character == ">" { inTag = false } else if !inTag { text.append(character) }
            }
            for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&"), ("&quot;", "\"")] {
                text = text.replacingOccurrences(of: entity, with: character)
            }
            out.append(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "　└ ", with: "└ "))
            rest = rest[close.upperBound...]
        }
        return out
    }

    /// The one feature Excel cannot hold is the one Numbers exists for, and the other way round.
    @Test func theFormatsAreNotOrderedByStrength() throws {
        let wb = Self.kitchenSink()
        let numbers = Self.profile(of: try Workbook(data: try wb.write(as: .numbers).data))
        let xlsx = Self.profile(of: try Workbook(data: try wb.write(as: .xlsx).data))
        #expect(numbers["several tables per sheet"] == true)
        #expect(xlsx["several tables per sheet"] == false)
    }
}
