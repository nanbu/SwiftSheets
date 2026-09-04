import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS
@testable import SheetXLSX
@testable import SheetNumbers
import SwiftSheets

/// The one streaming reader for every format (spec Appendix B.40): a file of any format opens with the same call
/// and yields the same rows, and each format's row-by-row reader sees what the whole-workbook reader sees.
@Suite struct StreamingFormatsTests {
    /// A workbook with the shapes a row-by-row reader has to get right: numbers, text, dates, times, booleans,
    /// errors, formulas, rich text, a merged range, a styled empty cell, empty rows and a far-away cell.
    static func sample() -> Workbook {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws.name = "Data"
        ws.append([.text("Item"), .text("Qty"), .text("Price"), .text("When")])
        for i in 1...30 {
            ws.append([.text("row\(i)"), .integer(i), .number(Decimal(i) + Decimal(string: "0.25")!),
                       .date(CivilDateTime(date: CivilDate(year: 2026, month: 1, day: i)!))])
        }
        ws["F2"] = .bool(true)
        ws["F3"] = .error("#N/A")
        ws["F4"] = .time(TimeOfDay(hour: 13, minute: 30, second: 0))
        ws["F5"] = .formula(FormulaExpr.parse("=B2*C2"), cached: .number(1.25))
        ws["F6"] = .richText([TextRun("赤", font: Font(bold: true)), TextRun("青")])
        ws["F7"] = .text("  余白  ")
        ws["F8"] = .text("line\nbreak")
        ws.merge("H2:I3")
        ws["H2"] = "結合"
        ws.style("A1:D1") { $0.font.bold = true }
        ws.style("G10") { $0.fill = .solid(Color(hex: "FFFF00")) }   // styled, empty
        ws["E100"] = .number(3.5)                                      // far away, after empty rows
        wb.sheets[0] = ws
        wb.addSheet(named: "Second")
        wb.sheets[1]["A1"] = "two"
        wb.sheets[1]["B2"] = .integer(2)
        return wb
    }

    /// The rows of the whole-workbook reader, in the streaming reader's shape, to compare against.
    static func rows(of sheet: Sheet, includeStyles: Bool = false) -> [(index: Int, cells: [(col: Int, value: CellValue?)])] {
        var byRow: [Int: [(Int, CellValue?)]] = [:]
        for (ref, cell) in sheet.table.cells where cell.value != nil || (includeStyles && cell.style != .default) {
            byRow[ref.row, default: []].append((ref.col, cell.value))
        }
        return byRow.keys.sorted().compactMap { r in
            let cells = byRow[r]!.sorted { $0.0 < $1.0 }
            guard cells.contains(where: { $0.1 != nil }) else { return nil }
            return (r, cells.map { (col: $0.0, value: $0.1) })
        }
    }

    static func check(_ format: SheetFormat, file: URL) async throws {
        let whole = try Workbook(contentsOf: file)
        let reader = try StreamingReader(contentsOf: file)
        #expect(reader.format == format)
        #expect(reader.sheetNames == whole.sheetNames, "\(format)")
        for sheet in whole.sheets {
            #expect(try reader.tableCount(inSheet: sheet.name) == 1)
            var streamed: [StreamedRow] = []
            try reader.forEachRow(inSheet: sheet.name) { streamed.append($0) }
            let expected = Self.rows(of: sheet)
            #expect(streamed.map(\.index) == expected.map(\.index), "\(format) \(sheet.name): the rows delivered are the rows that hold something")
            for (s, e) in zip(streamed, expected) {
                let got = s.cells.filter { $0.value != nil }.map { ($0.ref.col, $0.value) }
                let want = e.cells.filter { $0.value != nil }
                #expect(got.map(\.0) == want.map(\.col), "\(format) \(sheet.name) row \(s.index): columns")
                for (g, w) in zip(got, want) { #expect(g.1 == w.value, "\(format) \(sheet.name) row \(s.index) col \(g.0)") }
                #expect(s.cells.allSatisfy { $0.ref.row == s.index })
            }
            // the sequence form delivers the same rows
            var count = 0
            for try await row in reader.rows(inSheet: sheet.name) {
                #expect(row.index == streamed[count].index && row.cells.count == streamed[count].cells.count)
                count += 1
            }
            #expect(count == streamed.count, "\(format) \(sheet.name): rows() delivers what forEachRow delivers")
            // and stops when the loop does
            var first: Int?
            for try await row in reader.rows(inSheet: sheet.name) { first = row.index; break }
            #expect(first == streamed.first?.index)
        }
        // styles on request, and only on request
        var plain: CellStyle?, styled: CellStyle?
        try reader.forEachRow(inSheet: "Data") { if $0.index == 0 { plain = $0.cells.first?.style } }
        try reader.forEachRow(inSheet: "Data", options: StreamingReadOptions(includeStyles: true)) { if $0.index == 0 { styled = $0.cells.first?.style } }
        #expect(plain == nil && styled?.font.bold == true, "\(format): the heading is bold when styles are asked for")
        // formulas and dataOnly
        var formula: CellValue?, cached: CellValue?
        try reader.forEachRow(inSheet: "Data") { if $0.index == 4 { formula = $0.cells.first { $0.ref.col == 5 }?.value } }
        try reader.forEachRow(inSheet: "Data", options: StreamingReadOptions(dataOnly: true)) { if $0.index == 4 { cached = $0.cells.first { $0.ref.col == 5 }?.value } }
        #expect(formula?.formula != nil, "\(format): the formula comes as a formula")
        #expect(cached == .number(1.25), "\(format): dataOnly yields the cached value")
        // a second table does not exist on a one-grid sheet, and the reader says so rather than walking nothing
        #expect(throws: SheetError.self) { try reader.forEachRow(inSheet: "Data", table: 1) { _ in } }
        #expect(throws: SheetError.self) { try reader.forEachRow(inSheet: "Nope") { _ in } }
        // throwing from the handler stops the walk there
        struct Stop: Error {}
        var seen = 0
        #expect(throws: Stop.self) { try reader.forEachRow(inSheet: "Data") { _ in seen += 1; if seen == 3 { throw Stop() } } }
        #expect(seen == 3)
    }

    static func temporary(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-streamfmt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// The same file, written in each format, read row by row: the rows the whole-workbook reader sees.
    @Test(arguments: [SheetFormat.xlsx, .ods, .numbers])
    func theStreamingReaderSeesWhatTheWholeReaderSees(_ format: SheetFormat) async throws {
        let url = Self.temporary("sample.\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Self.sample().write(to: url, as: format)
        try await Self.check(format, file: url)
    }

    /// Delimited text goes through the same door: one sheet, every field a cell.
    @Test func delimitedTextThroughTheSameDoor() throws {
        let reader = try StreamingReader(data: Data("a,b,c\n1,,3\n\n4,5,6\n".utf8), format: .csv)
        #expect(reader.format == .csv && reader.sheetNames == ["Sheet1"])
        var rows: [StreamedRow] = []
        try reader.forEachRow(inSheet: "Sheet1") { rows.append($0) }
        #expect(rows.map(\.index) == [0, 1, 3], "the empty line is skipped, and the row numbers still count it")
        #expect(rows[1].cells.count == 3 && rows[1].cells[1].value == nil, "an empty field is a cell holding nothing")
        #expect(rows[2].values() == [.text("4"), .text("5"), .text("6")])
        var all = 0
        try reader.forEachRow(inSheet: "Sheet1", options: StreamingReadOptions(includesEmptyRows: true)) { _ in all += 1 }
        #expect(all == 4)
    }

    // MARK: - ODS

    /// ODS writes runs of rows and cells once with a repeat count; the streaming reader expands them the way the
    /// whole-workbook reader does — content as many times as the file says, padding never.
    @Test func odsRepeatsExpandAsTheWholeReaderExpandsThem() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.3">
        <office:automatic-styles><style:style style:name="ce1" style:family="table-cell"><style:text-properties fo:font-weight="bold"/></style:style></office:automatic-styles>
        <office:body><office:spreadsheet>
        <table:table table:name="First"><table:table-column table:number-columns-repeated="4"/>
        <table:table-row><table:table-cell office:value-type="string"><text:p>head</text:p></table:table-cell></table:table-row>
        <table:table-row table:number-rows-repeated="3"><table:table-cell office:value-type="float" office:value="7" table:number-columns-repeated="2"><text:p>7</text:p></table:table-cell><table:table-cell/><table:table-cell table:style-name="ce1"/></table:table-row>
        <table:table-row table:number-rows-repeated="5"><table:table-cell table:number-columns-repeated="4"/></table:table-row>
        <table:table-row><table:table-cell office:value-type="string"><text:p>after  the   gap</text:p><text:p>second <text:s text:c="3"/>para</text:p></table:table-cell></table:table-row>
        <table:table-row table:number-rows-repeated="1048000"><table:table-cell table:number-columns-repeated="4"/></table:table-row>
        </table:table>
        <table:table table:name="Second"><table:table-row><table:table-cell office:value-type="string"><text:p>two</text:p></table:table-cell></table:table-row></table:table>
        </office:spreadsheet></office:body></office:document-content>
        """
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8), stored: true)
        zip.add("content.xml", Data(content.utf8))
        let data = zip.finish()
        let reader = try ODSStreamingReader(data: data)
        #expect(reader.sheetNames == ["First", "Second"])
        var rows: [StreamedRow] = []
        try reader.forEachRow(inSheet: "First") { rows.append($0) }
        #expect(rows.map(\.index) == [0, 1, 2, 3, 9], "three repeats of the content row, the empty run skipped, then the row after it")
        #expect(rows[1].cells.map(\.ref.col) == [0, 1], "the repeated value cell is two cells; the empty and the styled-empty cell are not values")
        #expect(rows[1].cells.map(\.value) == [.integer(7), .integer(7)])
        #expect(rows[4].cells.first?.value == .text("after the gap\nsecond    para"), "ODF white space collapses; text:s is literal")
        var styled: [StreamedRow] = []
        try reader.forEachRow(inSheet: "First", options: StreamingReadOptions(includeStyles: true)) { styled.append($0) }
        #expect(styled[1].cells.map(\.ref.col) == [0, 1, 3], "with styles, the styled empty cell is delivered as a cell holding nothing")
        #expect(styled[1].cells[2].style?.font.bold == true)
        var withEmpty: [Int] = []
        try reader.forEachRow(inSheet: "First", options: StreamingReadOptions(includesEmptyRows: true)) { withEmpty.append($0.index) }
        #expect(withEmpty == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], "empty rows on request — but the trailing million is padding, not rows")
        // the whole-workbook reader agrees about what the sheet holds
        let whole = try Workbook(data: data)
        #expect(whole.sheets[0]["A10"] == .text("after the gap\nsecond    para"))
        #expect(whole.sheets[0].rowCount == 10)
        // the second sheet is reached by skipping the first, not by reading it
        var second: [CellValue?] = []
        try reader.forEachRow(inSheet: "Second") { second = $0.values() }
        #expect(second == [.text("two")])
    }


    // MARK: - Numbers

    /// A Numbers sheet is a canvas: `table:` reaches every table on it, in canvas order, and the count agrees
    /// with what `Workbook.inspect` says.
    @Test func numbersTablesAreReachedByIndex() throws {
        var wb = Workbook()
        wb.sheets[0].name = "Canvas"
        wb.sheets[0]["A1"] = "first"
        wb.sheets[0]["B2"] = .integer(1)
        let second = wb.sheets[0].addTable(named: "表2", anchor: CellRef("E1")!)
        wb.sheets[0].tables[second]["A1"] = "second"
        wb.sheets[0].tables[second]["C3"] = .number(Decimal(string: "2.5")!)
        wb.addSheet(named: "Other")
        wb.sheets[1]["A1"] = .bool(true)
        let data = try wb.data(as: .numbers)

        let reader = try StreamingReader(data: data)
        #expect(reader.format == .numbers && reader.sheetNames == ["Canvas", "Other"])
        #expect(try reader.tableCount(inSheet: "Canvas") == 2 && reader.tableCount(inSheet: "Other") == 1)
        #expect(try Workbook.inspect(data).sheets[0].tableCount == 2)
        var first: [StreamedRow] = [], secondRows: [StreamedRow] = []
        try reader.forEachRow(inSheet: "Canvas") { first.append($0) }
        try reader.forEachRow(inSheet: "Canvas", table: 1) { secondRows.append($0) }
        #expect(first.map(\.index) == [0, 1] && first[0].cells.first?.value == .text("first") && first[1].values(width: 2) == [nil, .integer(1)])
        #expect(secondRows.map(\.index) == [0, 2], "the second table's rows are its own, numbered from its own top")
        #expect(secondRows[1].cells.first?.value == .number(Decimal(string: "2.5")!))
        #expect(try NumbersStreamingReader(data: data).tableNames(inSheet: "Canvas") == ["Table 1", "表2"] ||
                NumbersStreamingReader(data: data).tableNames(inSheet: "Canvas").count == 2)
        #expect(throws: SheetError.self) { try reader.forEachRow(inSheet: "Canvas", table: 2) { _ in } }
        var other: CellValue?
        try reader.forEachRow(inSheet: "Other") { other = $0.cells.first?.value }
        #expect(other == .bool(true))
    }

    /// The document is indexed, not decoded: the tile parts are let go after indexing and expanded again only
    /// when a walk reaches them, one at a time; the whole-workbook reader sees the same values.
    @Test func numbersTilesAreExpandedOnlyWhenWalked() throws {
        var wb = Workbook()
        for i in 0..<20_000 { wb.sheets[0].append([.integer(i), .text("v\(i)"), .number(Decimal(i) + Decimal(string: "0.5")!)]) }
        let data = try wb.data(as: .numbers)
        let index = try NumbersObjectIndex(data: data)
        let tileFiles = index.fileCount - index.keptFileCount
        let tiles = (20_000 + 255) / 256   // a tile every 256 rows, each in its own part (the template adds one of its own)
        #expect(tileFiles >= tiles, "the tile parts are let go after indexing: \(tileFiles) of \(index.fileCount)")
        #expect(index.reexpansions == 0, "nothing is expanded again until a walk asks")
        let reader = try NumbersStreamingReader(index: index)
        var count = 0, total = 0
        var sum = Decimal(0)
        try reader.forEachRow(inSheet: "Sheet1") { row in
            count += 1
            if case .integer(let n)? = row.cells[0].value { total += n }
            if case .number(let d)? = row.cells[2].value { sum += d }
        }
        #expect(count == 20_000 && total == 19_999 * 20_000 / 2)
        #expect(sum == Decimal(19_999 * 20_000 / 2) + Decimal(20_000) * Decimal(string: "0.5")!)
        #expect(index.reexpansions == tiles, "each tile of the table was expanded exactly once by the walk")
        // stopping early leaves the rest folded
        var seen = 0
        struct Stop: Error {}
        #expect(throws: Stop.self) { try reader.forEachRow(inSheet: "Sheet1") { _ in seen += 1; if seen == 3 { throw Stop() } } }
        #expect(index.reexpansions == tiles + 1, "only the first tile was expanded for the walk that stopped")
    }

    /// A part whose archive header or object declares a length the part cannot hold — huge, or negative — is refused
    /// as malformed, and a table model claiming a negative column count yields no record. Without the guards
    /// (spec B.40.3) the index overflowed an addition or handed out a negative length, and the record slicer built
    /// a range that traps.
    @Test func hostileLengthsInANumbersPartAreRefusedNotTrapped() throws {
        // an archive header declaring Int.max bytes: nine varint bytes, the last without a continuation bit
        let hugeHeader = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        #expect(throws: SheetError.self) {
            try NumbersObjectIndex.walkArchives(hugeHeader, path: "Index/Hostile.iwa") { _, _, _, _ in }
        }
        // a well-formed header whose one object claims a negative length, then more bytes than the part has left
        var info = ProtoMessage(typeName: "TSP.MessageInfo")
        info.set("type", int: 1)
        var header = ProtoMessage(typeName: "TSP.ArchiveInfo")
        header.set("identifier", int: 7)
        for length in [-1, 1 << 40] {
            info.set("length", int: length)
            header.set("message_infos", messages: [info])
            let payload = IWAArchive(header: header, objects: []).encoded()
            #expect(throws: SheetError.self) {
                try NumbersObjectIndex.walkArchives(payload, path: "Index/Hostile.iwa") { _, _, _, length in
                    Issue.record(Comment(rawValue: "an object of length \(length) was handed out"))
                }
            }
        }
        // a tile row under a table model claiming a negative column count
        var rowInfo = ProtoMessage(typeName: "TST.TileRowInfo")
        rowInfo.set("cell_offsets", bytes: Data([0, 0]))
        rowInfo.set("cell_storage_buffer", bytes: Data([0x05, 0, 0, 0]))
        var visited = 0
        NumbersCells.forEachRecord(in: rowInfo, cols: -1) { _, _ in visited += 1 }
        #expect(visited == 0)
    }

    /// A document saved as a folder opens through the same door.
    @Test func numbersFolderThroughTheSameDoor() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "folder"
        wb.sheets[0]["A2"] = .integer(7)
        let data = try wb.data(as: .numbers)
        let dir = Self.temporary("Folder.numbers")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let zip = try ZipArchive(data: data)
        for name in zip.names where !name.hasSuffix("/") {
            let file = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.read(name).write(to: file)
        }
        let reader = try StreamingReader(contentsOf: dir)
        #expect(reader.format == .numbers)
        var values: [CellValue?] = []
        try reader.forEachRow(inSheet: "Sheet1") { values.append($0.cells.first?.value) }
        #expect(values == [.text("folder"), .integer(7)])
    }

    /// The fast road for decimal128 gives the same number as the general road, at the edges of the fast road.
    @Test func decimal128FastRoadAgreesWithTheGeneralRoad() {
        func record(mantissa: [UInt8], exponent: Int, negative: Bool) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 16)
            for (i, byte) in mantissa.prefix(15).enumerated() { b[i] = byte }
            let biased = exponent + CellStorage.decimal128Bias
            b[14] = (b[14] & 1) | UInt8((biased & 0x7F) << 1)
            b[15] = UInt8((biased >> 7) & 0x7F) | (negative ? 0x80 : 0)
            return b
        }
        let cases: [([UInt8], Int, Bool, Int?)] = [
            ([0x39, 0x30], -1, false, nil),                                        // 12345e-1 = 1234.5
            ([0x78], -1, false, 12),                                               // 120e-1 = 12
            ([0x64], 2, true, -10_000),                                            // -100e2
            ([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F], 0, false, Int.max),  // Int.max exactly
            ([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], 0, false, nil),      // 2^64 - 1: a decimal, not an Int
            ([0, 0, 0, 0, 0, 0, 0, 0, 1], 0, false, nil),                          // 2^64: past the fast road
            ([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], -3, false, nil),       // bit 0 of byte 14: the wide road
            ([1], 20, false, nil),                                                  // 1e20: whole, but not an Int
            ([0], 5, true, 0),                                                      // negative zero
        ]
        for (mantissa, exponent, negative, integer) in cases {
            let bytes = record(mantissa: mantissa, exponent: exponent, negative: negative)
            let general = CellStorage.decodeDecimal128(bytes)
            let (fast, whole) = bytes.withUnsafeBufferPointer { CellStorage.decodeDecimal128($0, at: 0) }
            #expect(fast == general, "\(mantissa) e\(exponent): fast \(fast) general \(general)")
            #expect(whole == integer, "\(mantissa) e\(exponent): integer \(String(describing: whole))")
            #expect(whole == Int("\(general)"), "the integer question answers as printing and parsing did")
        }
    }

    /// A hundred thousand rows of ODS come through with no more than a couple of pieces of the body in hand.
    @Test func aLargeODSIsWalkedAPieceAtATime() throws {
        var wb = Workbook()
        for i in 0..<100_000 { wb.sheets[0].append([.integer(i), .text("v\(i)")]) }
        let data = try wb.data(as: .ods)
        let reader = try ODSStreamingReader(data: data)
        var count = 0, total = 0
        try reader.forEachRow(inSheet: "Sheet1") { row in
            count += 1
            if case .integer(let n)? = row.cells.first?.value { total += n }
        }
        #expect(count == 100_000 && total == 99_999 * 100_000 / 2)
        #expect(ODSStreamingReader.lastLargestCarry <= 2 * ZipEntryStream.pieceSize * 4 + 1 << 20,
                "held \(ODSStreamingReader.lastLargestCarry) bytes of the body at once")
    }

    /// A protected ODS opens with its password and is refused by name without one.
    @Test func aProtectedODSOpensWithItsPassword() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "secret"
        let protected = try wb.data(as: .ods, options: WriteOptions(password: "合言葉"))
        #expect(throws: SheetError.self) { _ = try StreamingReader(data: protected) }
        let reader = try StreamingReader(data: protected, password: "合言葉")
        var first: CellValue?
        try reader.forEachRow(inSheet: "Sheet1") { first = $0.cells.first?.value }
        #expect(first == .text("secret"))
    }
}
