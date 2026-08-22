import Foundation
import Testing
import SheetCore
@testable import SheetCSV

/// CSV codec (spec §9): encodings and BOMs, dialect sniffing, RFC 4180 quoting, type inference, and what the writer
/// reports it could not keep.
@Suite struct CSVCodecTests {
    private func bytes(_ s: String, _ encoding: String.Encoding = .utf8) -> Data { s.data(using: encoding)! }

    private func read(_ s: String, encoding: String.Encoding = .utf8, options: ReadOptions = ReadOptions()) throws -> Sheet {
        try CSVCodec.read(bytes(s, encoding), options: options).sheets[0]
    }

    private func values(_ sheet: Sheet) -> [[CellValue?]] { sheet.rows() }

    private func writeText(_ wb: Workbook, options: WriteOptions = WriteOptions()) throws -> (String, WriteResult) {
        let result = try CSVCodec.write(wb, options: options)
        return (String(decoding: result.data, as: UTF8.self), result)
    }

    private func workbook(_ rows: [[CellValue?]]) -> Workbook {
        var sheet = Sheet(name: "Data")
        for (r, row) in rows.enumerated() { for (c, v) in row.enumerated() { sheet[r, c] = v } }
        return Workbook(sheets: [sheet])
    }

    // MARK: - Encodings

    @Test func utf8WithAndWithoutBOMReadIdentically() throws {
        let plain = try read("a,b\n1,2\n")
        let withBOM = try CSVCodec.read(Data([0xEF, 0xBB, 0xBF]) + bytes("a,b\n1,2\n")).sheets[0]
        #expect(values(plain) == [[.text("a"), .text("b")], [.text("1"), .text("2")]])
        #expect(values(withBOM) == values(plain))
        #expect(plain.name == "Sheet1")
    }

    @Test func utf16LittleEndianBOMIsDetected() throws {
        let data = Data([0xFF, 0xFE]) + bytes("名前,値\n太郎,1\n", .utf16LittleEndian)
        let sheet = try CSVCodec.read(data).sheets[0]
        #expect(values(sheet) == [[.text("名前"), .text("値")], [.text("太郎"), .text("1")]])
    }

    @Test func utf16BigEndianBOMIsDetected() throws {
        let data = Data([0xFE, 0xFF]) + bytes("x;y\n", .utf16BigEndian)
        #expect(values(try CSVCodec.read(data).sheets[0]) == [[.text("x"), .text("y")]])
    }

    @Test func explicitShiftJIS() throws {
        let data = bytes("品名,数量\nりんご,3\n", .shiftJIS)
        #expect(String(data: data, encoding: .utf8) == nil)   // the fixture really is not UTF-8
        let options = ReadOptions(csv: CSVReadOptions(encoding: .shiftJIS))
        let sheet = try CSVCodec.read(data, options: options).sheets[0]
        #expect(values(sheet) == [[.text("品名"), .text("数量")], [.text("りんご"), .text("3")]])
    }

    @Test func explicitUTF8StillStripsBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + bytes("a\n")
        let sheet = try CSVCodec.read(data, options: ReadOptions(csv: CSVReadOptions(encoding: .utf8))).sheets[0]
        #expect(sheet[0, 0] == .text("a"))
    }

    @Test func invalidUTF8ReportsByteOffset() throws {
        let data = bytes("ab,") + Data([0xFF]) + bytes("\n")
        #expect(throws: SheetError.malformedPart(path: "offset 3", detail: "invalid UTF-8 sequence")) {
            try CSVCodec.read(data)
        }
    }

    @Test func invalidUTF8OffsetCountsTheBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + bytes("x") + Data([0xC3])   // truncated 2-byte sequence
        #expect(throws: SheetError.malformedPart(path: "offset 4", detail: "invalid UTF-8 sequence")) {
            try CSVCodec.read(data)
        }
    }

    @Test func invalidShiftJISReportsOffset() throws {
        let data = bytes("あ,", .shiftJIS) + Data([0x82]) + bytes("\n")   // lone lead byte at offset 3
        do {
            _ = try CSVCodec.read(data, options: ReadOptions(csv: CSVReadOptions(encoding: .shiftJIS)))
            Issue.record("expected malformedPart")
        } catch let SheetError.malformedPart(path, _) {
            #expect(path == "offset 3")
        }
    }

    @Test func lossyReadReplacesBadBytesAndWarns() throws {
        let data = bytes("ab,") + Data([0xFF]) + bytes("c\n")
        let (wb, warnings) = try CSVCodec.readWithWarnings(data, options: ReadOptions(csv: CSVReadOptions(lossy: true)))
        #expect(wb.sheets[0][0, 1] == .text("\u{FFFD}c"))
        #expect(warnings.count == 1)
        #expect(warnings[0].kind == .degraded)
        #expect(warnings[0].message.contains("offset 3"))
        // `read` is the same thing minus the warnings
        #expect(try CSVCodec.read(data, options: ReadOptions(csv: CSVReadOptions(lossy: true))).sheets[0][0, 1] == .text("\u{FFFD}c"))
    }

    @Test func lossyReadOfLegacyEncoding() throws {
        let data = bytes("あ,", .shiftJIS) + Data([0xFF]) + bytes("い\n", .shiftJIS)
        let (wb, warnings) = try CSVCodec.readWithWarnings(data, options: ReadOptions(csv: CSVReadOptions(encoding: .shiftJIS, lossy: true)))
        #expect(wb.sheets[0][0, 0] == .text("あ"))
        #expect(wb.sheets[0][0, 1] == .text("\u{FFFD}い"))
        #expect(warnings.count == 1)
    }

    @Test func readSetsSourceInfo() throws {
        let wb = try CSVCodec.read(bytes("a\n"))
        #expect(wb.sourceInfo == SourceInfo(format: .csv))
        #expect(wb.preserved.sourceFormat == .csv)
        #expect(wb.sheets.count == 1)
    }

    // MARK: - Dialect

    @Test func sniffsSemicolon() throws {
        let sheet = try read("a;b;c\n1;2;3\n")
        #expect(values(sheet) == [[.text("a"), .text("b"), .text("c")], [.text("1"), .text("2"), .text("3")]])
    }

    @Test func sniffsTab() throws {
        let sheet = try read("a\tb\n1\t2\n")
        #expect(values(sheet) == [[.text("a"), .text("b")], [.text("1"), .text("2")]])
    }

    @Test func sniffIgnoresDelimitersInsideQuotes() throws {
        let sheet = try read("\"a;b;c\",d\n")
        #expect(values(sheet) == [[.text("a;b;c"), .text("d")]])
    }

    @Test func sniffTiesGoToComma() throws {
        #expect(values(try read("a,b;c\n")) == [[.text("a"), .text("b;c")]])
    }

    @Test func tsvFilenamePrefersTab() throws {
        let sheet = try read("a,b\tc\n", options: ReadOptions(filename: "data.tsv"))
        #expect(values(sheet) == [[.text("a,b"), .text("c")]])
        let sheetCSV = try read("a,b\tc\n", options: ReadOptions(filename: "data.csv"))
        #expect(values(sheetCSV) == [[.text("a"), .text("b\tc")]])
    }

    @Test func excelSepLineSetsDelimiterAndIsSkipped() throws {
        let sheet = try read("sep=;\r\na,b;c\r\n")
        #expect(values(sheet) == [[.text("a,b"), .text("c")]])
        #expect(sheet.nextAppendRow == 1)
        #expect(values(try read("sep=|\nx|y\n")) == [[.text("x"), .text("y")]])
    }

    @Test func explicitDialectOverridesSniffing() throws {
        let options = ReadOptions(csv: CSVReadOptions(dialect: .semicolon))
        #expect(values(try read("a,b;c\n", options: options)) == [[.text("a,b"), .text("c")]])
    }

    // MARK: - Parsing

    @Test func quotingRoundTrip() throws {
        let rows: [[CellValue?]] = [[.text("a,b"), .text("say \"hi\""), .text("line1\nline2"), .text(" padded ")]]
        let (text, _) = try writeText(workbook(rows))
        #expect(text == "\"a,b\",\"say \"\"hi\"\"\",\"line1\nline2\",\" padded \"\r\n")
        let back = try read(text)
        #expect(values(back) == rows)
    }

    @Test func mixedLineEndings() throws {
        let sheet = try read("a\r\nb\nc\rd")
        #expect(values(sheet) == [[.text("a")], [.text("b")], [.text("c")], [.text("d")]])
        #expect(sheet.nextAppendRow == 4)
    }

    @Test func emptyLinesBecomeEmptyRecords() throws {
        let sheet = try read("a\n\nb\n")
        #expect(sheet[0, 0] == .text("a"))
        #expect(sheet[1, 0] == nil)
        #expect(sheet[2, 0] == .text("b"))
        #expect(sheet.nextAppendRow == 3)
    }

    @Test func trailingNewlineAddsNoRecord() throws {
        #expect(try read("a\n").nextAppendRow == 1)
        #expect(try read("a").nextAppendRow == 1)
        #expect(try read("a\r\n").nextAppendRow == 1)
        #expect(try read("").nextAppendRow == 0)
    }

    @Test func emptyFieldsProduceNoCell() throws {
        let sheet = try read("a,,c\n,\n")
        #expect(sheet[0, 0] == .text("a"))
        #expect(sheet[0, 1] == nil)
        #expect(sheet[0, 2] == .text("c"))
        #expect(sheet.row(1) == [nil, nil, nil])
        #expect(sheet.nextAppendRow == 2)
    }

    @Test func whitespaceIsPreserved() throws {
        #expect(values(try read("  a , b  \n")) == [[.text("  a "), .text(" b  ")]])
    }

    @Test func quotedFieldKeepsNewlinesAndDelimiters() throws {
        let sheet = try read("\"x\r\ny\",\"1,2\"\nz\n")
        #expect(values(sheet) == [[.text("x\r\ny"), .text("1,2")], [.text("z"), nil]])
    }

    // MARK: - Types

    @Test func noInferenceByDefault() throws {
        let sheet = try read("01234,1-2,3.5,TRUE,2026-08-22\n")
        #expect(values(sheet) == [[.text("01234"), .text("1-2"), .text("3.5"), .text("TRUE"), .text("2026-08-22")]])
    }

    @Test func inferenceOn() throws {
        let options = ReadOptions(csv: CSVReadOptions(inferTypes: true, dateFormats: ["yyyy/MM/dd"]))
        let sheet = try read("42,-7,0,01234,3.5,1e3,.5,true,FALSE,2026/08/22,2026-08-22,2026-08-22T13:45:10,1-2\n", options: options)
        let row = sheet.row(0)
        #expect(row[0] == .integer(42))
        #expect(row[1] == .integer(-7))
        #expect(row[2] == .integer(0))
        #expect(row[3] == .text("01234"))
        #expect(row[4] == .number(Decimal(string: "3.5")!))
        #expect(row[5] == .number(Decimal(1000)))
        #expect(row[6] == .number(Decimal(string: "0.5")!))
        #expect(row[7] == .bool(true))
        #expect(row[8] == .bool(false))
        let day = CivilDate(year: 2026, month: 8, day: 22)!
        #expect(row[9] == .date(CivilDateTime(date: day)))
        #expect(row[10] == .date(CivilDateTime(date: day)))
        #expect(row[11] == .date(CivilDateTime(date: day, time: TimeOfDay(hour: 13, minute: 45, second: 10))))
        #expect(row[12] == .text("1-2"))
    }

    @Test func inferenceKeepsHugeIntegersAsNumbers() throws {
        let options = ReadOptions(csv: CSVReadOptions(inferTypes: true))
        let sheet = try read("99999999999999999999,+5,1.5E-3,1e,1.2.3,TrUe\n", options: options)
        let row = sheet.row(0)
        #expect(row[0] == .number(Decimal(string: "99999999999999999999")!))
        #expect(row[1] == .integer(5))
        #expect(row[2] == .number(Decimal(string: "0.0015")!))
        #expect(row[3] == .text("1e"))
        #expect(row[4] == .text("1.2.3"))
        #expect(row[5] == .bool(true))
    }

    @Test func explicitUTF16HonoursBOMAndDefaultsToBigEndian() throws {
        let options = ReadOptions(csv: CSVReadOptions(encoding: .utf16))
        let le = Data([0xFF, 0xFE]) + bytes("a,b\n", .utf16LittleEndian)
        #expect(values(try CSVCodec.read(le, options: options).sheets[0]) == [[.text("a"), .text("b")]])
        let be = bytes("a,b\n", .utf16BigEndian)
        #expect(values(try CSVCodec.read(be, options: options).sheets[0]) == [[.text("a"), .text("b")]])
        let odd = Data([0xFF, 0xFE, 0x61])
        #expect(throws: SheetError.malformedPart(path: "offset 2", detail: "truncated UTF-16 code unit")) {
            try CSVCodec.read(odd)
        }
    }

    // MARK: - Writing

    @Test func writeDefaults() throws {
        let wb = workbook([[.text("a"), .integer(1)], [.number(Decimal(string: "2.5")!), .bool(true)]])
        let result = try CSVCodec.write(wb)
        #expect([UInt8](result.data.prefix(3)) != [0xEF, 0xBB, 0xBF])
        #expect(String(decoding: result.data, as: UTF8.self) == "a,1\r\n2.5,TRUE\r\n")
        #expect(result.warnings.isEmpty)
        #expect(result.suggestion == nil)
    }

    @Test func writeIncludesBOMOnRequest() throws {
        let wb = workbook([[.text("a")]])
        let utf8 = try CSVCodec.write(wb, options: WriteOptions(csv: CSVWriteOptions(includeBOM: true)))
        #expect([UInt8](utf8.data) == [0xEF, 0xBB, 0xBF, 0x61, 0x0D, 0x0A])
        let utf16 = try CSVCodec.write(wb, options: WriteOptions(csv: CSVWriteOptions(encoding: .utf16LittleEndian, includeBOM: true)))
        #expect([UInt8](utf16.data.prefix(4)) == [0xFF, 0xFE, 0x61, 0x00])
        // and the result reads back through BOM detection
        #expect(try CSVCodec.read(utf16.data).sheets[0][0, 0] == .text("a"))
    }

    @Test func writeTSVWithLF() throws {
        let wb = workbook([[.text("a\tb"), .text("c")], [.text("d"), nil]])
        let options = WriteOptions(csv: CSVWriteOptions(dialect: .tab, newline: .lf))
        let (text, _) = try writeText(wb, options: options)
        #expect(text == "\"a\tb\"\tc\nd\t\n")
    }

    @Test func emptySheetWritesNothing() throws {
        let result = try CSVCodec.write(Workbook())
        #expect(result.data.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test func unencodableTextThrowsUnlessLossy() throws {
        let wb = workbook([[.text("ok"), .text("😀")]])
        let strict = WriteOptions(csv: CSVWriteOptions(encoding: .shiftJIS))
        #expect(throws: SheetError.unsupportedFeature("text at B1 cannot be represented in \(String.localizedName(of: .shiftJIS))")) {
            try CSVCodec.write(wb, options: strict)
        }
        let lossy = WriteOptions(csv: CSVWriteOptions(encoding: .shiftJIS, lossy: true))
        let result = try CSVCodec.write(wb, options: lossy)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].kind == .degraded)
        #expect(result.warnings[0].location == CellRef(row: 0, col: 1))
        #expect(result.warnings[0].sheet == "Data")
        let text = String(data: result.data, encoding: .shiftJIS)
        #expect(text?.hasPrefix("ok,?") == true && text?.hasSuffix("\r\n") == true)   // the emoji became "?" marks
    }

    @Test func shiftJISWriteRoundTrip() throws {
        let wb = workbook([[.text("日本語"), .text("テスト")]])
        let result = try CSVCodec.write(wb, options: WriteOptions(csv: CSVWriteOptions(encoding: .shiftJIS)))
        #expect(result.data == "日本語,テスト\r\n".data(using: .shiftJIS)!)
        let back = try CSVCodec.read(result.data, options: ReadOptions(csv: CSVReadOptions(encoding: .shiftJIS)))
        #expect(values(back.sheets[0]) == [[.text("日本語"), .text("テスト")]])
    }

    @Test func multiSheetWorkbookWarnsOnce() throws {
        var wb = workbook([[.text("first")]])
        wb.addSheet(named: "Second")
        wb.addSheet(named: "Third")
        let (text, result) = try writeText(wb)
        #expect(text == "first\r\n")
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].kind == .dropped)
        #expect(result.warnings[0].message == "2 other sheet(s) not written: CSV holds a single sheet")
        #expect(result.suggestion?.format == .xlsx)
    }

    @Test func sheetSelectionByName() throws {
        var wb = workbook([[.text("first")]])
        wb.addSheet(named: "Second")
        wb.sheets["Second"]?[0, 0] = .text("second")
        let (text, _) = try writeText(wb, options: WriteOptions(csv: CSVWriteOptions(sheet: "Second")))
        #expect(text == "second\r\n")
        #expect(throws: SheetError.invalidWorkbook("no sheet named Nope")) {
            try CSVCodec.write(wb, options: WriteOptions(csv: CSVWriteOptions(sheet: "Nope")))
        }
    }

    @Test func styledCellsWarnExactlyOnce() throws {
        var sheet = Sheet(name: "S")
        sheet[0, 0] = .text("a"); sheet.style(at: CellRef(row: 0, col: 0)) { $0.font.bold = true }
        sheet[0, 1] = .text("b"); sheet.style(at: CellRef(row: 0, col: 1)) { $0.numberFormat = "0.00" }
        sheet[1, 0] = .integer(1)
        let result = try CSVCodec.write(Workbook(sheets: [sheet]))
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0] == ConversionWarning(.degraded, message: "formatting and formula structure are not kept in CSV"))
        #expect(result.warnings[0].location == nil)
        #expect(String(decoding: result.data, as: UTF8.self) == "a,b\r\n1,\r\n")
    }

    @Test func formulaWritesCachedValue() throws {
        let wb = workbook([[.integer(2), .formula(FormulaExpr.parse("=A1*2"), cached: .integer(4))]])
        let (text, result) = try writeText(wb)
        #expect(text == "2,4\r\n")
        #expect(result.warnings.count == 1)   // the formula-structure summary only
        #expect(result.warnings[0].location == nil)
    }

    @Test func formulaWithoutCachedValueWritesTextAndWarns() throws {
        let wb = workbook([[.formula(FormulaExpr.parse("=SUM(A2:A3)"), cached: nil)]])
        let (text, result) = try writeText(wb)
        #expect(text == "=SUM(A2:A3)\r\n")
        #expect(result.warnings.count == 2)
        let perCell = result.warnings.first { $0.location != nil }
        #expect(perCell?.location == CellRef(row: 0, col: 0))
        #expect(perCell?.sheet == "Data")
        #expect(perCell?.message == "formula without a cached value written as text")
    }

    @Test func valueRendering() throws {
        let day = CivilDate(year: 2026, month: 8, day: 22)!
        var sheet = Sheet(name: "V")
        sheet[0, 0] = .date(CivilDateTime(date: day))
        sheet[0, 1] = .date(CivilDateTime(date: day, time: TimeOfDay(hour: 9, minute: 5, second: 7)))
        sheet[0, 2] = .time(TimeOfDay(hour: 23, minute: 59, second: 1))
        sheet[0, 3] = .error("#N/A")
        sheet[0, 4] = .richText([TextRun("rich "), TextRun("text")])
        sheet[0, 5] = .number(Decimal(string: "1234567.891")!)
        sheet[0, 6] = .bool(false)
        sheet[0, 7] = .duration(.seconds(3661))
        let (text, _) = try writeText(Workbook(sheets: [sheet]))
        #expect(text == "2026-08-22,2026-08-22T09:05:07,23:59:01,#N/A,rich text,1234567.891,FALSE,1:01:01\r\n")
        let custom = WriteOptions(csv: CSVWriteOptions(dateFormat: "yyyy/M/d HH:mm"))
        let (custom_, _) = try writeText(Workbook(sheets: [sheet]), options: custom)
        #expect(custom_.hasPrefix("2026/8/22 00:00,2026/8/22 09:05,"))
    }

    // MARK: - Round trip

    @Test func readWriteReadRoundTrip() throws {
        let source = "name,qty,note\r\n\"Smith, J\",01234,\"said \"\"ok\"\"\"\r\n\r\n太郎,,\"multi\nline\"\r\n"
        let first = try CSVCodec.read(bytes(source))
        let written = try CSVCodec.write(first)
        let second = try CSVCodec.read(written.data)
        #expect(values(second.sheets[0]) == values(first.sheets[0]))
        #expect(second.sheets[0].nextAppendRow == first.sheets[0].nextAppendRow)
        // the empty record comes back as a row of empty fields (every row gets `columnCount` fields)
        #expect(String(decoding: written.data, as: UTF8.self) == source.replacingOccurrences(of: "\r\n\r\n", with: "\r\n,,\r\n"))
    }

    @Test func inferredTypesSurviveRoundTrip() throws {
        let options = ReadOptions(csv: CSVReadOptions(inferTypes: true))
        let first = try CSVCodec.read(bytes("1,2.5,TRUE,2026-08-22,text\n"), options: options)
        let written = try CSVCodec.write(first, options: WriteOptions(csv: CSVWriteOptions(newline: .lf)))
        #expect(String(decoding: written.data, as: UTF8.self) == "1,2.5,TRUE,2026-08-22,text\n")
        let second = try CSVCodec.read(written.data, options: options)
        #expect(values(second.sheets[0]) == values(first.sheets[0]))
    }
}
