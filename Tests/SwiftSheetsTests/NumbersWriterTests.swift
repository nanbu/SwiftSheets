import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// Spec §11: values, merges, sizes, several sheets / tables; formulas fall back to cached values with a warning (B.8).
/// Judges: our own reader, and numbers-parser through Tests/NumbersParity/verify_with_numbers_parser.py (run separately).
@Suite struct NumbersWriterTests {
    static let outDir: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-numbers-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func sampleWorkbook() -> Workbook {
        var wb = Workbook()
        wb.sheets[0].name = "売上"
        var s = wb.sheets[0]
        s.tables[0].name = "Sales"
        s.append(["部門", "金額", "率", "日付", "済", "時間"])
        s.append(["営業", 1_250_000, 0.125, CellValue(CivilDate(year: 2026, month: 9, day: 1)!), true, CellValue(Duration.seconds(3661))])
        s.append(["開発", -3.5, CellValue(Decimal(string: "12345678901234567890.5")!), CellValue(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!, time: TimeOfDay(hour: 13, minute: 30))), false, nil])
        s["A5"] = "merged"; s.merge("A5:C6")
        s["G1"] = Formula("=SUM(B2:B3)"); s[cell: "G1"].value = .formula(FormulaExpr.parse("SUM(B2:B3)"), cached: .number(Decimal(string: "1249996.5")!))
        s["H1"] = "quote \"q\" & <tag>\nline2"
        s.setWidth(30, ofColumn: "A"); s.setHeight(40, ofRow: 0)
        s.freezePanes = CellRef(row: 1, col: 0)
        let t2 = s.addTable(named: "Second", anchor: CellRef("A12")!)
        s.tables[t2]["A1"] = "second table"; s.tables[t2]["B2"] = 42
        wb.sheets[0] = s
        wb.addSheet(named: "Notes")
        wb.sheets[1]["A1"] = "second sheet"; wb.sheets[1]["B1"] = 7
        return wb
    }

    @Test func roundTripThroughOurReader() throws {
        let wb = Self.sampleWorkbook()
        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("formula") })
        #expect(SheetFormat.detect(from: result.data) == .numbers)
        let url = Self.outDir.appendingPathComponent("sample.numbers")
        try result.data.write(to: url)
        let reread = try NumbersCodec.read(result.data)
        let (back, warnings) = (reread.workbook, reread.warnings)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(back.sheetNames == ["売上", "Notes"])
        let s = back.sheets[0]
        #expect(s.tables.count == 2)
        #expect(s.tables[0].name == "Sales" && s.tables[1].name == "Second")
        #expect(s["A1"] == .text("部門") && s["B2"] == .integer(1_250_000) && s["C2"] == .number(Decimal(string: "0.125")!))
        #expect(s["D2"]?.dateValue?.date.description == "2026-09-01")
        #expect(s["D3"]?.dateValue?.time.hour == 13 && s["D3"]?.dateValue?.time.minute == 30)
        #expect(s["E2"] == .bool(true) && s["E3"] == .bool(false))
        #expect(s["F2"]?.durationValue == .seconds(3661))
        #expect(s["B3"] == .number(Decimal(string: "-3.5")!))
        #expect(s["C3"] == .number(Decimal(string: "12345678901234567890.5")!))
        #expect(s["G1"] == .number(Decimal(string: "1249996.5")!))   // the cached value, no formula
        #expect(s["H1"] == .text("quote \"q\" & <tag>\nline2"))
        #expect(s.merges == [CellRange("A5:C6")!] && s["A5"] == .text("merged") && s["B5"] == nil)
        #expect(s.columnDimension("A").width.map { abs($0 - 30) < 0.5 } == true)
        #expect(s.rowDimension(0).height == 40)
        #expect(s.freezePanes == CellRef(row: 1, col: 0))
        #expect(s.tables[1]["A1"] == .text("second table") && s.tables[1]["B2"] == .integer(42))
        #expect(s.tables[1].anchor.row > 0)
        #expect(back.sheets[1]["A1"] == .text("second sheet") && back.sheets[1]["B1"] == .integer(7))
        #expect(back.sourceInfo?.format == .numbers)
    }

    @Test func templateIsLeftIntactExceptForTheTable() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        let out = try NumbersCodec.write(wb).data
        let doc = try NumbersDocument(data: out)
        let template = try NumbersDocument(data: try Data(contentsOf: NumbersCodec.templateURL))
        // the stylesheet, theme and view state objects are untouched
        for id in template.identifiers(ofType: "TSS.StylesheetArchive") + template.identifiers(ofType: "TSS.ThemeArchive") {
            #expect(doc.object(id) == template.object(id), "object \(id)")
        }
        #expect(doc.blob("preview.jpg") == template.blob("preview.jpg"))
        #expect(doc.blob("Metadata/Properties.plist") == template.blob("Metadata/Properties.plist"))
        #expect(doc.blob("Metadata/DocumentIdentifier") != template.blob("Metadata/DocumentIdentifier"))
        // the invariants Numbers checks when opening a document
        #expect(doc.integrityProblems().isEmpty, "\(doc.integrityProblems().prefix(5))")
        // every component registered in the package metadata exists and vice versa for tiles
        let pkg = doc.object(NumbersDocument.packageID)!
        let components = Set(pkg.messages("components").compactMap { $0.int("identifier") })
        for id in doc.identifiers(ofType: "TST.Tile") { #expect(components.contains(id), "tile \(id) not registered") }
        #expect(pkg.int("last_object_identifier") == doc.locations.keys.max())
    }

    /// Numbers refuses to open a document whose package metadata names objects that are not there — which is what
    /// happened while the template's tiles were being replaced (they were removed, their components were not).
    @Test func packageMetadataStaysConsistent() throws {
        let wb = Self.sampleWorkbook()
        let doc = try NumbersDocument(data: try NumbersCodec.write(wb).data)
        #expect(doc.integrityProblems().isEmpty, "\(doc.integrityProblems())")
        #expect(doc.identifiers(ofType: "TST.Tile").allSatisfy { doc.object($0) != nil })
        // and everything is stored, not deflated, as Numbers writes it
        let zip = try ZipArchive(data: try NumbersCodec.write(wb).data)
        #expect(zip.entries.values.allSatisfy { $0.method == 0 }, "every entry stored")
    }

    @Test func largeTableUsesSeveralTiles() throws {
        var wb = Workbook()
        for r in 0..<600 { wb.sheets[0][r, 0] = .integer(r); wb.sheets[0][r, 1] = .text("row \(r)") }
        let out = try NumbersCodec.write(wb).data
        let doc = try NumbersDocument(data: out)
        let model = doc.identifiers(ofType: "TST.TableModelArchive").compactMap { doc.object($0) }.first { $0.string("table_name") == "Table 1" }
        #expect(model?.message("base_data_store")?.message("tiles")?.messages("tiles").count == 3)
        let back = try NumbersCodec.read(out).workbook
        #expect(back.sheets[0][599, 1] == .text("row 599") && back.sheets[0][300, 0] == .integer(300) && back.sheets[0].rowCount == 600)
    }

    @Test func decimal128RoundTrip() {
        for text in ["0", "1", "-1", "42", "0.1", "-0.07", "1250000", "12345678901234567890.5", "1e30", "3.14159265358979323846", "-123456.789", "1e-7"] {
            let d = Decimal(string: text)!
            let bytes = CellStorage.encodeDecimal128(d)
            #expect(CellStorage.decodeDecimal128(bytes) == d, "\(text)")
        }
    }

    /// Cell formatting on the way out: each distinct style becomes a variation of the table's own default, listed
    /// in the table's style list and named by the cells that use it.
    ///
    /// A round trip is deliberately *not* the identity. The template a Numbers write starts from says its body text
    /// is Helvetica Neue 10, wrapped and top-aligned, so a cell that states nothing comes back saying that — which
    /// is what the document really looks like. What the cells *do* state has to survive unchanged.
    @Test func cellFormattingRoundTrip() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "head"; ws["B1"] = "amount"
        ws["A2"] = "apple"; ws["B2"] = .number(Decimal(string: "1234.5")!)
        ws["B3"] = .number(Decimal(string: "0.125")!)
        ws["C2"] = .date(CivilDateTime(date: CivilDate(year: 2026, month: 8, day: 25)!))
        ws.style("A1:C1") {
            $0.font.bold = true
            $0.font.size = 14
            $0.font.color = Color(hex: "FFFFFF")
            $0.fill = .solid(Color(hex: "1F4E79"))
            $0.alignment.horizontal = .center
            $0.alignment.vertical = .center
        }
        ws.style("B2") { $0.numberFormat = "#,##0.00"; $0.font.italic = true }
        ws.style("B3") { $0.numberFormat = "0.0%" }
        ws.style("C2") { $0.numberFormat = "yyyy/mm/dd" }
        ws.style("A2") { $0.border.bottom = Side(style: .thin, color: Color(hex: "FF0000")) }
        wb.sheets[0] = ws

        let result = try wb.write(as: .numbers)
        #expect(!result.warnings.contains { $0.message.contains("formatting is not written") })
        let back = try NumbersCodec.read(result.data).workbook.sheets[0]

        let head = back.style("A1")
        #expect(head.font.bold)
        #expect(head.font.size == 14)
        #expect(head.font.color == Color(hex: "FFFFFFFF"))
        #expect(head.fill.foregroundColor == Color(hex: "FF1F4E79"))
        #expect(head.alignment.horizontal == .center)
        #expect(head.alignment.vertical == .center)

        #expect(back.style("B2").font.italic)
        #expect(back.style("B2").numberFormat == "#,##0.00")
        #expect(back.style("B3").numberFormat == "0.0%")
        #expect(back.style("C2").numberFormat == "yyyy/mm/dd")
        #expect(back.style("A2").border.bottom.style == .thin)
        #expect(back.style("A2").border.bottom.color == Color(hex: "FFFF0000"))
        #expect(back["B2"] == .number(Decimal(string: "1234.5")!))

        let doc = try NumbersDocument(data: result.data)
        #expect(doc.integrityProblems().isEmpty, "\(doc.integrityProblems().prefix(5))")

        // the style list names objects of another component, and Numbers keeps that crossing in the metadata
        let store = try #require(doc.object(doc.identifiers(ofType: "TST.TableModelArchive").first ?? 0)?.message("base_data_store"))
        let listID = try #require(store.reference("styleTable"))
        let named = try #require(doc.object(listID)).messages("entries").compactMap { $0.reference("reference") }
        #expect(!named.isEmpty)
        let listComponent = try #require(doc.componentID(forObject: listID))
        let recorded = doc.object(NumbersDocument.packageID)?.messages("components")
            .first { $0.int("identifier") == listComponent }?
            .messages("external_references").compactMap { $0.int("object_identifier") } ?? []
        #expect(Set(named).isSubset(of: Set(recorded)), "every style the list names is recorded as an external reference")

        // Numbers names a font by its PostScript name, not by its family
        let stylesheet = named.compactMap { doc.object($0)?.message("char_properties")?.string("font_name") }
        #expect(stylesheet.allSatisfy { !$0.contains(" ") }, "\(stylesheet)")
    }

    /// Numbers describes one presentation per format, so Excel's sections, colours and conditions are reported.
    @Test func partialAndUnexpressibleNumberFormatsAreReported() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0]["A2"] = 2
        wb.sheets[0].style("A1") { $0.numberFormat = "[Red][>100]0.00;[Blue]0.00" }
        wb.sheets[0].style("A2") { $0.numberFormat = "* #,##0_);_(* (#,##0)" }
        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.kind == .substituted && $0.message.contains("colours, conditions") })
        let back = try NumbersCodec.read(result.data).workbook.sheets[0]
        #expect(back["A1"] == .integer(1) && back["A2"] == .integer(2), "the values are never lost to a format")
    }

    @Test func crossFormatWarnings() throws {
        let xlsx = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/preservation/charts-and-friends.xlsx")
        let wb = try Workbook(contentsOf: xlsx)
        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.kind == .dropped })
        let back = try NumbersCodec.read(result.data).workbook
        #expect(back.sheetNames == ["Data", "Notes"])
        #expect(back.sheets[0]["A1"] == .text("Item") && back.sheets[0]["B3"] == .integer(5))
        try result.data.write(to: Self.outDir.appendingPathComponent("from-xlsx.numbers"))
    }
}
