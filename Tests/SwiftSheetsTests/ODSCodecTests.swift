import Foundation
import Testing
import SheetCore
import SheetXLSX
@testable import SheetODS
import SwiftSheets

/// ODS codec (spec chapter 8, Appendix B.8): package shape, self round trip, RLE, formulas, dates, cross-format
/// warnings, and LibreOffice as the external judge (skipped when soffice is not installed).
@Suite(.serialized) struct ODSCodecTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    static let soffice = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
    static var hasLibreOffice: Bool { FileManager.default.fileExists(atPath: soffice) }
    static let tmp: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-ods-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }

    private func contentXML(_ ods: Data) throws -> String {
        let zip = try ZipInspection(data: ods)
        return String(decoding: zip.entry(named: "content.xml")!, as: UTF8.self)
    }

    /// `soffice --headless --convert-to <ext>`; returns the converted file and the converter's log text.
    @discardableResult
    private func convert(_ file: URL, to ext: String) throws -> (URL, String) {
        let outdir = Self.tmp.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        let profile = Self.tmp.appendingPathComponent("lo-profile")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.soffice)
        p.arguments = ["-env:UserInstallation=file://\(profile.path)", "--headless", "--convert-to", ext, "--outdir", outdir.path, file.path]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let out = outdir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "." + ext)
        try #require(FileManager.default.fileExists(atPath: out.path), Comment(rawValue: "LibreOffice did not produce \(out.lastPathComponent): \(log)"))
        return (out, log)
    }

    // MARK: - Fixtures

    /// Every CellValue kind, styles, number formats, dimensions, merges, freeze, hidden sheet, names, link, note, metadata.
    private func sampleWorkbook() -> Workbook {
        var ws = Sheet(name: "Data")
        ws["A1"] = .text("  padded  ")
        ws["B1"] = .text("multi\nline")
        ws["C1"] = .text("<A&B> \"q\"")
        ws["D1"] = .integer(42)
        ws["E1"] = .number(Decimal(string: "3.14159")!)
        ws["F1"] = .bool(true)
        ws["G1"] = .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!))
        ws["H1"] = .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!, time: TimeOfDay(hour: 13, minute: 30)))
        ws["I1"] = .time(TimeOfDay(hour: 9, minute: 30, second: 15))
        ws["J1"] = .formula(FormulaExpr.parse("=SUM(D1:E1)"), cached: .number(Decimal(string: "45.14159")!))
        ws["K1"] = .error("#DIV/0!")
        ws["L1"] = .richText([TextRun("rich", font: Font(bold: true)), TextRun(" text")])
        ws["M1"] = .duration(.seconds(26 * 3600 + 90))
        ws["N1"] = .formula(FormulaExpr.parse("=Hidden!A1"), cached: .text("secret"))
        ws["A2"] = .text("styled")
        ws.style("A2") {
            $0.font = Font(name: "Arial", size: 14, bold: true, italic: true, color: Color(hex: "112233"))
            $0.fill = .solid(Color(hex: "BFD7F5"))
            $0.border = Border(left: Side(style: .thin, color: .black), right: Side(style: .medium, color: Color(hex: "FF0000")), top: Side(style: .thick, color: .black), bottom: Side(style: .double, color: .black))
            $0.alignment = Alignment(horizontal: .center, vertical: .top, wrapText: true)
        }
        ws["B2"] = .number(Decimal(string: "1234.5")!); ws.style("B2") { $0.numberFormat = "#,##0.00" }
        ws["C2"] = .number(Decimal(string: "0.25")!); ws.style("C2") { $0.numberFormat = "0%" }
        ws["D2"] = .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!)); ws.style("D2") { $0.numberFormat = "yyyy-mm-dd" }
        ws["E2"] = .time(TimeOfDay(hour: 9, minute: 30)); ws.style("E2") { $0.numberFormat = "h:mm" }
        ws["A3"] = .text("merged"); ws.merge("A3:C4")
        ws["A5"] = .text("link"); ws[cell: "A5"].hyperlink = Hyperlink(target: "https://example.com/")
        ws["B5"] = .text("noted"); ws[cell: "B5"].comment = CellNote("a note\nsecond line", author: "tester")
        ws.setWidth(20, ofColumn: "A")
        ws.setColumnDimension("C") { $0.hidden = true }
        ws.setHeight(30, ofRow: 1)
        ws.setRowDimension(3) { $0.hidden = true }
        ws.freezePanes(at: "B2")
        ws.definedNames["Local"] = "Data!$A$2"
        var hidden = Sheet(name: "Hidden")
        hidden["A1"] = .text("secret")
        hidden.state = .hidden
        var wb = Workbook(sheets: [ws, hidden])
        wb.definedNames["MyRange"] = "Data!$A$1:$B$2"
        wb.metadata.creator = "fixture"
        wb.metadata.title = "ODS sample"
        wb.metadata.description = "round trip"
        wb.metadata.keywords = "ods, test"
        wb.metadata.created = Date(timeIntervalSince1970: 1_767_225_600)
        return wb
    }

    // MARK: - 1. Package shape

    @Test func packageStartsWithStoredMimetypeAndListsEveryEntry() throws {
        let data = try ODSCodec.write(sampleWorkbook()).data
        let bytes = [UInt8](data)
        #expect(String(decoding: bytes[30..<38], as: UTF8.self) == "mimetype")
        #expect(bytes[8] == 0 && bytes[9] == 0, "mimetype must be stored (method 0)")
        #expect(String(decoding: bytes[38..<(38 + 46)], as: UTF8.self) == "application/vnd.oasis.opendocument.spreadsheet")
        #expect(SheetFormat.detect(from: data) == .ods)
        let zip = try ZipInspection(data: data)
        let manifest = String(decoding: zip.entry(named: "META-INF/manifest.xml")!, as: UTF8.self)
        for name in zip.entryNames where name != "mimetype" && name != "META-INF/manifest.xml" {
            #expect(manifest.contains("manifest:full-path=\"\(name)\""), Comment(rawValue: "manifest lists \(name)"))
        }
        #expect(manifest.contains("manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\""))
        #expect(try ODSCodec.canDecode(ZipInspection(data: data)))
    }

    // MARK: - 2. Self round trip

    @Test func selfRoundTripKeepsEverything() throws {
        let original = sampleWorkbook()
        let result = try ODSCodec.write(original)
        #expect(result.warnings.isEmpty, Comment(rawValue: "\(result.warnings)"))
        let reread = try ODSCodec.read(result.data)
        let (back, readWarnings) = (reread.workbook, reread.warnings)
        #expect(readWarnings.isEmpty, Comment(rawValue: "\(readWarnings)"))
        #expect(back.sheetNames == ["Data", "Hidden"])
        let ws = back.sheets[0], src = original.sheets[0]
        for a1 in ["A1", "B1", "C1", "D1", "E1", "F1", "G1", "H1", "I1", "K1", "M1", "A2", "B2", "C2", "D2", "E2", "A3", "A5", "B5"] {
            #expect(ws[a1] == src[a1], Comment(rawValue: a1))
        }
        #expect(ws["J1"] == src["J1"])
        #expect(ws["N1"] == src["N1"])
        #expect(ws["L1"] == .text("rich text"))
        #expect(ws.merges == src.merges)
        #expect(ws.definedNames["Local"] == "Data!$A$2")
        #expect(ws.columnDimension("A").width == 20)
        #expect(ws.columnDimension("C").hidden)
        #expect(ws.rowDimension(1).height == 30)
        #expect(ws.rowDimension(3).hidden)
        #expect(ws.freezePanes == CellRef(row: 1, col: 1))
        #expect(back.sheets[1].state == .hidden)
        #expect(back.sheets[1]["A1"] == .text("secret"))
        #expect(back.definedNames["MyRange"] == "Data!$A$1:$B$2")
        #expect(ws.cell("A5")?.hyperlink?.target == "https://example.com/")
        #expect(ws.cell("B5")?.comment == CellNote("a note\nsecond line", author: "tester"))
        let st = ws.style("A2")
        #expect(st.font.bold && st.font.italic)
        #expect(st.font.name == "Arial" && st.font.size == 14)
        #expect(st.font.color == Color(hex: "112233"))
        #expect(st.fill == .solid(Color(hex: "BFD7F5")))
        #expect(st.border.left.style == .thin && st.border.right.style == .medium && st.border.top.style == .thick && st.border.bottom.style == .double)
        #expect(st.border.right.color == Color(hex: "FF0000"))
        #expect(st.alignment.horizontal == .center && st.alignment.vertical == .top && st.alignment.wrapText)
        #expect(ws.style("B2").numberFormat == "#,##0.00")
        #expect(ws.style("C2").numberFormat == "0%")
        #expect(ws.style("D2").numberFormat == "yyyy-mm-dd")
        #expect(ws.style("E2").numberFormat == "h:mm")
        #expect(ws.style("D1") == .default)
        #expect(back.metadata.creator == "fixture")
        #expect(back.metadata.title == "ODS sample")
        #expect(back.metadata.description == "round trip")
        #expect(back.metadata.keywords == "ods, test")
        #expect(back.metadata.created == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(back.sourceInfo == SourceInfo(format: .ods, application: SwiftSheetsInfo.generator))
        #expect(back.preserved.sourceFormat == .ods)
        #expect(back.preserved.opaqueParts.isEmpty)
        #expect(back.activeIndex == 0)
    }

    @Test func dataOnlyReadingYieldsCachedValues() throws {
        let data = try ODSCodec.write(sampleWorkbook()).data
        let wb = try ODSCodec.read(data, options: ReadOptions(dataOnly: true)).workbook
        #expect(wb.sheets[0]["J1"] == .number(Decimal(string: "45.14159")!))
        #expect(wb.dataOnly)
    }

    // MARK: - 3. RLE

    @Test func sparseSheetIsRunLengthEncoded() throws {
        var ws = Sheet(name: "Sparse")
        ws["A1"] = .text("top")
        ws["J1000"] = .integer(7)
        let data = try ODSCodec.write(Workbook(sheets: [ws])).data
        let xml = try contentXML(data)
        #expect(xml.components(separatedBy: "<table:table-row").count - 1 < 50)
        #expect(xml.contains("table:number-rows-repeated=\"998\""))
        let back = try ODSCodec.read(data).workbook.sheets[0]
        #expect(back.rowCount == 1000)
        #expect(back.columnCount == 10)
        #expect(back["J1000"] == .integer(7))
    }

    /// A merged title band whose anchor holds nothing still has to come out as a span — the writer hangs
    /// `number-columns-spanned` on the anchor cell, and the reader has to keep a row whose only content is that
    /// span. Before this, `merge("A1:C1")` on an untouched anchor came back from ODS with no merges at all.
    @Test func mergesWithAnEmptyAnchorSurviveTheRoundTrip() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet.merge("A1:C1")     // horizontal, anchor empty
        sheet.merge("E1:E3")     // vertical, anchor empty
        sheet["A2"] = "body"
        wb.sheets[0] = sheet
        let back = try ODSCodec.read(try ODSCodec.write(wb).data).workbook
        #expect(back.sheets[0].merges.map(\.a1).sorted() == ["A1:C1", "E1:E3"])
        #expect(back.sheets[0]["A2"] == .text("body"))
        // and again, so that reading does not lose the anchor the next write needs
        let twice = try ODSCodec.read(try ODSCodec.write(back).data).workbook
        #expect(twice.sheets[0].merges.map(\.a1).sorted() == ["A1:C1", "E1:E3"])
    }

    /// `A1:XFD1048576` is a merge anyone can make in Excel. Writing it used to build one covered-cell reference per
    /// position — seventeen billion of them — and the process was killed before the first byte was written.
    @Test func aSheetWideMergeDoesNotBlowUpTheWriter() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet["A1"] = "everything"
        sheet.merge("A1:XFD1048576")
        wb.sheets[0] = sheet
        let start = Date()
        let data = try ODSCodec.write(wb).data
        #expect(Date().timeIntervalSince(start) < 5.0)
        #expect(data.count < 100_000)
        let back = try ODSCodec.read(data).workbook
        #expect(back.sheets[0].merges.map(\.a1) == ["A1:XFD1048576"])
        #expect(back.sheets[0]["A1"] == .text("everything"))
    }

    /// `paddingRepeat` only judges *empty* runs.    /// `paddingRepeat` only judges *empty* runs. A repeat that carries a value multiplies just as hard — the row
    /// below asks for 16,384 × 1,048,576 cells out of one kilobyte of XML — so the reader also has a budget for how
    /// much a document may expand to, and reports having stopped (spec §12: no allocation sized by the file's own
    /// numbers).
    @Test func aRepeatedRowOfRepeatedCellsIsClippedToTheCellBudget() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.3">
        <office:body><office:spreadsheet><table:table table:name="Bomb">
        <table:table-row table:number-rows-repeated="1048576"><table:table-cell office:value-type="string" table:number-columns-repeated="16384"><text:p>x</text:p></table:table-cell></table:table-row>
        </table:table></office:spreadsheet></office:body></office:document-content>
        """
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8), stored: true)
        zip.add("content.xml", Data(content.utf8))
        let start = Date()
        let result = try ODSCodec.read(zip.finish())
        let (wb, warnings) = (result.workbook, result.warnings)
        #expect(Date().timeIntervalSince(start) < 30.0)
        #expect(wb.sheets[0].cells.count <= ODSReader.maxCells)
        #expect(warnings.contains { $0.kind == .degraded && $0.message.contains("stopped there") })
        #expect(wb.sheets[0]["A1"] == .text("x"))
    }

    @Test func hugeTrailingRepeatIsNotExpanded() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.3">
        <office:body><office:spreadsheet><table:table table:name="Big">
        <table:table-column table:number-columns-repeated="16384"/>
        <table:table-row><table:table-cell office:value-type="float" office:value="1"><text:p>1</text:p></table:table-cell><table:table-cell table:number-columns-repeated="16383"/></table:table-row>
        <table:table-row table:number-rows-repeated="2"><table:table-cell table:number-columns-repeated="16384"/></table:table-row>
        <table:table-row><table:table-cell table:number-columns-repeated="3"/><table:table-cell office:value-type="string"><text:p>x</text:p></table:table-cell><table:table-cell table:number-columns-repeated="16380"/></table:table-row>
        <table:table-row table:number-rows-repeated="1048576"><table:table-cell table:number-columns-repeated="16384"/></table:table-row>
        </table:table></office:spreadsheet></office:body></office:document-content>
        """
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8), stored: true)
        zip.add("content.xml", Data(content.utf8))
        let start = Date()
        let wb = try ODSCodec.read(zip.finish()).workbook
        #expect(Date().timeIntervalSince(start) < 1.0)
        let ws = wb.sheets[0]
        #expect(ws.rowCount == 4)
        #expect(ws.columnCount == 4)
        #expect(ws["A1"] == .integer(1))
        #expect(ws["D4"] == .text("x"))
        #expect(ws.cells.count == 2)
        #expect(ws.columnDimensions.isEmpty)
    }

    // MARK: - 5. Formulas

    @Test func formulasUseTheOpenFormulaDialect() throws {
        var ws = Sheet(name: "F")
        ws["A1"] = .integer(1); ws["B2"] = .integer(2); ws["C3"] = .integer(3)
        ws["D1"] = .formula(FormulaExpr.parse("=SUM(A1:B2,C3)"), cached: .integer(6))
        ws["E1"] = .formula(.unparsed("WEIRD(A1", dialect: .xlsx), cached: .text("fallback"))
        let result = try ODSCodec.write(Workbook(sheets: [ws]))
        let xml = try contentXML(result.data)
        #expect(xml.contains("table:formula=\"of:=SUM([.A1:.B2];[.C3])\""))
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].kind == .degraded && result.warnings[0].location == CellRef("E1"))
        let back = try ODSCodec.read(result.data).workbook.sheets[0]
        #expect(back["D1"]?.formula == FormulaExpr.parse("=SUM(A1:B2,C3)"))
        #expect(back["D1"]?.cachedValue == .integer(6))
        #expect(back["E1"] == .text("fallback"))
    }

    // MARK: - 6. Cross-format warnings

    @Test func foreignOpaquePartsAreReportedWhenWritingODS() throws {
        let wb = try XLSXCodec.read(fixture("preservation/charts-and-friends.xlsx")).workbook
        let count = wb.preserved.opaqueParts.count
        #expect(count > 0)
        let result = try ODSCodec.write(wb)
        let dropped = result.warnings.filter { $0.kind == .dropped }
        #expect(dropped.count == 1)
        #expect(dropped.first?.message.contains("\(count) part(s)") == true)
        #expect(result.suggestion?.format == .xlsx)
        let back = try ODSCodec.read(result.data).workbook
        for (ref, cell) in wb.sheets[0].cells where cell.value != nil {
            #expect(back.sheets[0][ref]?.cachedValue == cell.value?.cachedValue, Comment(rawValue: "\(ref)"))
        }
        #expect(back.preserved.opaqueParts.isEmpty)
    }

    /// ODS has one `<table:table>` per sheet, so a Numbers canvas loses every table but the first — with a warning.
    @Test func extraTablesOfASheetAreReportedWhenWritingODS() throws {
        var ws = Sheet(name: "Canvas")
        ws["A1"] = .text("first")
        let second = ws.addTable(named: "Second", anchor: CellRef("D1")!)
        ws.tables[second]["A1"] = .text("second")
        let result = try ODSCodec.write(Workbook(sheets: [ws]))
        let dropped = result.warnings.filter { $0.kind == .dropped }
        #expect(dropped.count == 1)
        #expect(dropped.first?.subject == .sheets && dropped.first?.sheet == "Canvas")
        #expect(dropped.first?.message.contains("1 other table(s)") == true)
        let xml = try contentXML(result.data)
        #expect(xml.contains("first") && !xml.contains("second"))
        let back = try ODSCodec.read(result.data).workbook.sheets[0]
        #expect(back.tables.count == 1 && back["A1"] == .text("first"))
    }

    // MARK: - 7. Dates and times

    @Test func dateAndTimeValuesDecodeFromISOText() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.3">
        <office:body><office:spreadsheet><table:table table:name="T"><table:table-column/>
        <table:table-row>
        <table:table-cell office:value-type="date" office:date-value="2026-09-01T13:30:00"><text:p>x</text:p></table:table-cell>
        <table:table-cell office:value-type="date" office:date-value="2026-09-01"><text:p>x</text:p></table:table-cell>
        <table:table-cell office:value-type="time" office:time-value="PT26H00M00S"><text:p>x</text:p></table:table-cell>
        <table:table-cell office:value-type="time" office:time-value="PT09H30M00S"><text:p>x</text:p></table:table-cell>
        <table:table-cell office:value-type="float" office:value="2.5"><text:p>2.5</text:p></table:table-cell>
        <table:table-cell office:value-type="percentage" office:value="0.25"><text:p>25%</text:p></table:table-cell>
        <table:table-cell office:value-type="boolean" office:boolean-value="false"><text:p>FALSE</text:p></table:table-cell>
        <table:table-cell office:value-type="string" office:string-value="attr wins"><text:p>ignored</text:p></table:table-cell>
        <table:table-cell office:value-type="string"><text:p><text:s text:c="2"/>a<text:tab/>b <text:s/>c</text:p><text:p>second</text:p></table:table-cell>
        <table:table-cell table:formula="of:=1/0" office:value-type="string" office:string-value=""><text:p>#DIV/0!</text:p></table:table-cell>
        </table:table-row></table:table></office:spreadsheet></office:body></office:document-content>
        """
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8), stored: true)
        zip.add("content.xml", Data(content.utf8))
        let ws = try ODSCodec.read(zip.finish()).workbook.sheets[0]
        #expect(ws["A1"] == .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!, time: TimeOfDay(hour: 13, minute: 30))))
        #expect(ws["B1"] == .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!)))
        #expect(ws["C1"] == .duration(.seconds(26 * 3600)))
        #expect(ws["D1"] == .time(TimeOfDay(hour: 9, minute: 30)))
        #expect(ws["E1"] == .number(Decimal(string: "2.5")!))
        #expect(ws["F1"] == .number(Decimal(string: "0.25")!))
        #expect(ws["G1"] == .bool(false))
        #expect(ws["H1"] == .text("attr wins"))
        #expect(ws["I1"] == .text("  a\tb  c\nsecond"))
        #expect(ws["J1"]?.formula == FormulaExpr.parse("=1/0"))
        #expect(ws["J1"]?.cachedValue == .error("#DIV/0!"))
    }

    @Test func inexpressibleStylesAreReportedOnce() throws {
        var ws = Sheet(name: "W")
        ws["A1"] = .integer(1); ws.style("A1") { $0.font.color = .theme(4); $0.numberFormat = "#,##0_);(#,##0)" }
        ws["A2"] = .integer(2); ws.style("A2") { $0.fill = .solid(.indexed(12)); $0.numberFormat = "#,##0_);(#,##0)" }
        ws["A3"] = .integer(3); ws.style("A3") { $0.numberFormat = "# ?/?" }
        let result = try ODSCodec.write(Workbook(sheets: [ws]))
        let degraded = result.warnings.filter { $0.kind == .degraded }
        #expect(degraded.count == 1 && degraded[0].message.contains("colour"))
        let substituted = result.warnings.filter { $0.kind == .substituted }
        #expect(substituted.count == 2)
        #expect(substituted.contains { $0.message.contains("#,##0_);(#,##0)") && $0.message.contains("first section") })
        #expect(substituted.contains { $0.message.contains("# ?/?") && $0.message.contains("General") })
        let back = try ODSCodec.read(result.data).workbook.sheets[0]
        #expect(back.style("A1").numberFormat == "#,##0 ")   // the `_)` padding of the first section is a space in ODF
        #expect(back.style("A3").numberFormat == "General")
        #expect(back["A1"] == .integer(1))
    }

    @Test func missingContentIsAMalformedPart() throws {
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8), stored: true)
        #expect(throws: SheetError.malformedPart(path: "content.xml", detail: "content.xml missing from the package")) { try ODSCodec.read(zip.finish()).workbook }
        zip.add("content.xml", Data("<office:document-content><unclosed>".utf8))
        #expect(throws: SheetError.self) { try ODSCodec.read(zip.finish()).workbook }
    }

    // MARK: - LibreOffice-generated corpus (read without LibreOffice present)

    @Test func readsLibreOfficeGeneratedFixtures() throws {
        let ods = try ODSCodec.read(fixture("ods/styled.ods")).workbook
        let xlsx = try XLSXCodec.read(fixture("styled.xlsx")).workbook
        #expect(ods.sheetNames == xlsx.sheetNames)
        #expect(ods.sheets[1].state == .hidden)
        #expect(ods.sourceInfo?.application?.hasPrefix("LibreOffice") == true)
        let a = ods.sheets[0], b = xlsx.sheets[0]
        for (ref, cell) in b.cells where cell.value != nil {
            let expected = cell.value!, got = a[ref]
            switch expected {
            case .formula(let f, _): #expect(got?.formula == f, Comment(rawValue: "\(ref)"))
            case .number(let d): #expect(got?.doubleValue == Double("\(d)"), Comment(rawValue: "\(ref)"))
            case .bool: #expect(got?.cachedValue == expected, Comment(rawValue: "\(ref)"))   // LibreOffice writes booleans as =TRUE() formulas
            default: #expect(got == expected, Comment(rawValue: "\(ref)"))
            }
        }
        #expect(a.merges == b.merges)
        #expect(a.style("A1").font.bold)
        #expect(a.style("A1").font.italic)
        #expect(a.style("A1").font.size == 14)
        #expect(a.style("A1").font.name == "Arial")
        #expect(a.columnDimension("C").hidden)
        #expect(a.rowDimension(3).hidden)
        #expect(a.rowDimension(1).height.map { abs($0 - 30) < 0.5 } == true)
        #expect(a.cell("A6")?.hyperlink?.target == "https://example.com/")
        #expect(a.style("E1").numberFormat == "yyyy/m/d")
        #expect(a.style("H1").numberFormat == "0%")

        let charts = try ODSCodec.read(fixture("ods/charts-and-friends.ods")).workbook
        let source = try XLSXCodec.read(fixture("preservation/charts-and-friends.xlsx")).workbook
        for (ref, cell) in source.sheets[0].cells where cell.value?.cachedValue != nil {   // LibreOffice computes the formula the source left uncached
            #expect(charts.sheets[0][ref]?.cachedValue == cell.value?.cachedValue, Comment(rawValue: "\(ref)"))
        }
        #expect(charts.sheets[0].style("A1").font.bold)
        #expect(charts.sheets[0].cell("A1")?.comment?.text == "first column")
        #expect(charts.preserved.opaqueParts.keys.contains("Object 1/content.xml"))
        #expect(charts.preserved.contentTypeOverrides["Object 1/content.xml"] == "text/xml")
        #expect(!charts.preserved.opaqueParts.keys.contains { $0.hasPrefix("Thumbnails/") })
        // writing back re-registers the parts and says they are no longer linked
        let rewritten = try ODSCodec.write(charts)
        #expect(rewritten.warnings.contains { $0.kind == .dropped && $0.message.contains("not re-linked") })
        let manifest = String(decoding: try ZipInspection(data: rewritten.data).entry(named: "META-INF/manifest.xml")!, as: UTF8.self)
        #expect(manifest.contains("manifest:full-path=\"Object 1/content.xml\" manifest:media-type=\"text/xml\""))
    }

    // MARK: - 4. LibreOffice as the judge

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeKeepsAMergeWithAnEmptyAnchor() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet.merge("A1:C1")
        sheet["A2"] = "body"
        wb.sheets[0] = sheet
        let file = Self.tmp.appendingPathComponent("empty-anchor-merge.ods")
        try ODSCodec.write(wb).data.write(to: file)
        let (xlsx, log) = try convert(file, to: "xlsx")
        #expect(log.contains("-> "), Comment(rawValue: log))
        let back = try XLSXCodec.read(try Data(contentsOf: xlsx)).workbook
        #expect(back.sheets[0].merges.map(\.a1) == ["A1:C1"])
        #expect(back.sheets[0]["A2"] == .text("body"))
    }

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeOpensOurODS() throws {
        let wb = sampleWorkbook()
        let file = Self.tmp.appendingPathComponent("ours.ods")
        try ODSCodec.write(wb).data.write(to: file)
        let (xlsx, log) = try convert(file, to: "xlsx")
        #expect(log.contains("-> "), Comment(rawValue: log))
        let back = try XLSXCodec.read(try Data(contentsOf: xlsx)).workbook
        #expect(back.sheetNames == ["Data", "Hidden"])
        let ws = back.sheets[0], src = wb.sheets[0]
        #expect(ws["A1"] == src["A1"])
        #expect(ws["B1"] == src["B1"])
        #expect(ws["C1"] == src["C1"])
        #expect(ws["D1"]?.doubleValue == 42)
        #expect(ws["E1"]?.doubleValue == 3.14159)
        #expect(ws["F1"] == .bool(true))
        #expect(ws["G1"]?.dateValue?.date == CivilDate(year: 2026, month: 9, day: 1))
        #expect(ws["H1"]?.dateValue == CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!, time: TimeOfDay(hour: 13, minute: 30)))
        #expect(ws["I1"]?.timeValue == TimeOfDay(hour: 9, minute: 30, second: 15))
        #expect(ws["J1"]?.formula == src["J1"]?.formula)
        #expect(ws["J1"]?.cachedValue?.doubleValue == 45.14159)
        #expect(ws["N1"]?.formula == FormulaExpr.parse("=Hidden!A1"))
        #expect(ws["N1"]?.cachedValue == .text("secret"))
        #expect(ws["K1"]?.stringValue == "#DIV/0!")   // an error with no formula is only expressible as text in ODS
        #expect(ws["L1"] == .text("rich text"))
        #expect(ws["B2"]?.doubleValue == 1234.5)
        #expect(ws["C2"]?.doubleValue == 0.25)
        #expect(ws.merges == src.merges)
        #expect(ws.style("A2").font.bold && ws.style("A2").font.italic)
        #expect(ws.style("B2").numberFormat == "#,##0.00")
        #expect(ws.style("C2").numberFormat == "0%")
        #expect(ws.freezePanes == CellRef(row: 1, col: 1))
        // LibreOffice writes `hidden="true"` (xsd:boolean words); the XLSX reader accepts both spellings
        #expect(ws.columnDimension("C").hidden, "column C hidden")
        #expect(ws.rowDimension(3).hidden, "row 4 hidden")
        #expect(back.sheets[1].state == .hidden)
        #expect(back.sheets[1]["A1"] == .text("secret"))
        #expect(back.definedNames["MyRange"]?.replacingOccurrences(of: "'", with: "") == "Data!$A$1:$B$2")
        #expect(ws.cell("A5")?.hyperlink?.target == "https://example.com/")
    }

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeConvertsXLSXFixturesThatWeRead() throws {
        for (name, path) in [("styled", "styled.xlsx"), ("charts-and-friends", "preservation/charts-and-friends.xlsx")] {
            let source = try XLSXCodec.read(fixture(path)).workbook
            let (ods, log) = try convert(Self.fixtures.appendingPathComponent(path), to: "ods")
            #expect(log.contains("-> "), Comment(rawValue: log))
            let back = try ODSCodec.read(try Data(contentsOf: ods)).workbook
            #expect(back.sheetNames == source.sheetNames, Comment(rawValue: name))
            for (i, sheet) in source.sheets.enumerated() {
                let got = back.sheets[i]
                #expect(got.state == sheet.state, Comment(rawValue: "\(name)/\(sheet.name)"))
                #expect(got.merges == sheet.merges, Comment(rawValue: "\(name)/\(sheet.name)"))
                for (ref, cell) in sheet.cells where cell.value != nil {
                    switch cell.value! {
                    case .formula(let f, _): #expect(got[ref]?.formula == f, Comment(rawValue: "\(name)/\(ref)"))
                    case .number(let d): #expect(got[ref]?.doubleValue == Double("\(d)"), Comment(rawValue: "\(name)/\(ref)"))
                    case .bool(let b): #expect(got[ref]?.cachedValue == .bool(b), Comment(rawValue: "\(name)/\(ref)"))   // LibreOffice: =TRUE()
                    case let v: #expect(got[ref] == v, Comment(rawValue: "\(name)/\(ref)"))
                    }
                }
                // LibreOffice's headless converter writes no view settings (no `Tables` map in settings.xml), so
                // freeze panes cannot survive this direction — only their absence is checked here; the reverse
                // direction (ours → LibreOffice → xlsx) proves the settings.xml layout in `libreOfficeOpensOurODS`.
                if sheet.freezePanes != nil { #expect(got.freezePanes == nil || got.freezePanes == sheet.freezePanes, Comment(rawValue: "\(name)/\(sheet.name)")) }
            }
            #expect(back.sheets[0].style("A1").font.bold == source.sheets[0].style("A1").font.bold, Comment(rawValue: name))
        }
    }

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeReadsOurRewriteOfItsOwnFile() throws {
        // ODS → model → ODS (with the opaque chart parts re-registered) → LibreOffice must still open it
        let wb = try ODSCodec.read(fixture("ods/charts-and-friends.ods")).workbook
        let file = Self.tmp.appendingPathComponent("rewritten.ods")
        try ODSCodec.write(wb).data.write(to: file)
        let (xlsx, log) = try convert(file, to: "xlsx")
        #expect(log.contains("-> "), Comment(rawValue: log))
        let back = try XLSXCodec.read(try Data(contentsOf: xlsx)).workbook
        #expect(back.sheets[0]["A1"] == wb.sheets[0]["A1"])
        #expect(back.sheets[0].cell("A1")?.comment?.text == "first column" || back.preserved.opaqueParts.keys.contains { $0.hasPrefix("xl/comments") })
    }

    /// Auto-filters travel as anonymous database ranges (ODF 1.3 §9.4) — LibreOffice's own spelling.
    @Test func autoFilterRoundTrip() throws {
        var wb = Workbook()
        wb.sheets[0].name = "Data"
        wb.sheets[0].append([.text("部門"), .text("金額")])
        wb.sheets[0].append([.text("営業"), .integer(100)])
        wb.sheets[0].autoFilterA1 = "A1:B2"
        wb.addSheet(named: "Plain")
        wb.sheets[1]["A1"] = "no filter"
        let ods = try ODSCodec.write(wb).data
        let xml = try contentXML(ods)
        #expect(xml.contains("<table:database-ranges>"))
        #expect(xml.contains(#"table:display-filter-buttons="true""#))
        #expect(xml.contains(#"table:target-range-address="Data.A1:Data.B2""#))
        let back = try ODSCodec.read(ods).workbook
        #expect(back.sheets[0].autoFilter == CellRange("A1:B2"))
        #expect(back.sheets[1].autoFilter == nil)

        try withKnownIssue("LibreOffice is not installed", isIntermittent: false) {
            try #require(Self.hasLibreOffice)
            let url = Self.tmp.appendingPathComponent("filter.ods")
            try ods.write(to: url)
            let (xlsx, log) = try convert(url, to: "xlsx")
            #expect(log.contains("convert"))
            let viaLO = try XLSXCodec.read(try Data(contentsOf: xlsx)).workbook
            #expect(viaLO.sheets[0].autoFilter == CellRange("A1:B2"), "LibreOffice kept the filter")
            // and a LibreOffice-produced ODS reads back the same way
            let (roundTrip, _) = try convert(xlsx, to: "ods")
            #expect(try ODSCodec.read(try Data(contentsOf: roundTrip)).workbook.sheets[0].autoFilter == CellRange("A1:B2"))
        } when: {
            !Self.hasLibreOffice
        }
    }
}
