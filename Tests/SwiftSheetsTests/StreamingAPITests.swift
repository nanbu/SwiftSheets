import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
@testable import SheetCSV
import SwiftSheets

/// The three additions of spec Appendix B.39.10: reading only the sheets asked for, CSV one record at a time,
/// and rows as a sequence to iterate.
@Suite struct SheetSelectionTests {
    static func threeSheets() throws -> Data {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "one"
        wb.addSheet(named: "Two"); wb.sheets[1]["A1"] = "two"; wb.sheets[1]["B2"] = Formula("=1+1")
        wb.sheets[1].style("A1") { $0.font.bold = true }
        wb.addSheet(named: "Three"); wb.sheets[2]["A1"] = "three"
        return try wb.data(as: .xlsx)
    }

    /// Only the named sheet is parsed; the others are there, empty, marked, and reported.
    @Test func onlyTheSelectedSheetIsRead() throws {
        let data = try Self.threeSheets()
        let result = try Workbook.read(data, options: ReadOptions(sheets: .named(["Two"])))
        let wb = result.workbook
        #expect(wb.sheetNames == ["Sheet1", "Two", "Three"], "the sheet list is the file's")
        #expect(wb.sheets[1]["A1"] == .text("two") && wb.sheets[1][cell: "A1"].font.bold)
        #expect(wb.sheets[0].table.cells.isEmpty && wb.sheets[2].table.cells.isEmpty)
        #expect(wb.sheets[0].preserved.isUnread && wb.sheets[2].preserved.isUnread && !wb.sheets[1].preserved.isUnread)
        #expect(result.warnings.filter { $0.kind == .degraded && $0.subject == .sheets }.count == 2)
        let byIndex = try Workbook(data: data, options: ReadOptions(sheets: .indices([2])))
        #expect(byIndex.sheets[2]["A1"] == .text("three") && byIndex.sheets[0].preserved.isUnread)
    }

    /// An unread XLSX sheet is written back exactly as it arrived — a same-format save loses nothing.
    @Test func anUnreadSheetIsWrittenBackAsItArrived() throws {
        let data = try Self.threeSheets()
        var wb = try Workbook(data: data, options: ReadOptions(sheets: .named(["Two"])))
        wb.sheets[1]["C3"] = "edited"
        let out = try wb.data(as: .xlsx)
        let before = try ZipArchive(data: data), after = try ZipArchive(data: out)
        #expect(try after.read("xl/worksheets/sheet1.xml") == before.read("xl/worksheets/sheet1.xml"))
        #expect(try after.read("xl/worksheets/sheet3.xml") == before.read("xl/worksheets/sheet3.xml"))
        let back = try Workbook(data: out)
        #expect(back.sheets[0]["A1"] == .text("one") && back.sheets[2]["A1"] == .text("three") && back.sheets[1]["C3"] == .text("edited"))
        // cells put into an unread sheet cannot be saved into bytes that were never parsed: reported
        var touched = try Workbook(data: data, options: ReadOptions(sheets: .named(["Two"])))
        touched.sheets[0]["Z9"] = 1
        let result = try touched.write(as: .xlsx)
        #expect(result.warnings.contains { $0.kind == .dropped && $0.sheet == "Sheet1" })
    }

    /// ODS and Numbers cannot carry bytes; the sheet comes back empty, and writing says so.
    @Test func odsAndNumbersReportWhatTheyCouldNotFillIn() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "one"
        wb.addSheet(named: "Two"); wb.sheets[1]["A1"] = "two"
        for format in [SheetFormat.ods, .numbers] {
            let data = try wb.data(as: format)
            let read = try Workbook.read(data, options: ReadOptions(sheets: .named(["Two"])))
            #expect(read.workbook.sheets[1]["A1"] == .text("two"), "\(format)")
            #expect(read.workbook.sheets[0].preserved.isUnread && read.workbook.sheets[0].table.cells.isEmpty, "\(format)")
            #expect(read.warnings.contains { $0.kind == .degraded && $0.sheet == "Sheet1" }, "\(format)")
            let written = try read.workbook.write(as: format)
            #expect(written.warnings.contains { $0.kind == .dropped && $0.sheet == "Sheet1" }, "\(format): writing says the sheet is empty for a reason")
        }
    }
}

@Suite struct CSVStreamingTests {
    static func temporary(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-csv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Written one record at a time, read back one record at a time and by the ordinary reader: the same values.
    @Test func recordsGoOutAndComeBackOneAtATime() throws {
        let url = Self.temporary("s.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try CSVStreamingWriter(url: url)
        try writer.append([.text("name"), .text("qty"), .text("note")])
        try writer.append([.text("りんご, 赤"), .integer(3), .text("line\nbreak")])
        try writer.append([.text("\"quoted\""), .number(1.5), nil])
        for i in 0..<20_000 { try writer.append([.text("r\(i)"), .integer(i), .text(String(repeating: "あ", count: i % 7))]) }
        try writer.close()

        var rows: [[CellValue?]] = []
        let reader = try CSVStreamingReader(contentsOf: url, options: CSVReadOptions(inferTypes: true))
        try reader.forEachRow { rows.append($0) }
        #expect(rows.count == 20_003)
        #expect(rows[1] == [.text("りんご, 赤"), .integer(3), .text("line\nbreak")])
        #expect(rows[2] == [.text("\"quoted\""), .number(1.5), nil])
        #expect(rows[20_001] == [.text("r19998"), .integer(19_998), .text(String(repeating: "あ", count: 19_998 % 7))])
        #expect(rows[20_002] == [.text("r19999"), .integer(19_999), nil], "an empty field is nil")
        let whole = try Workbook(contentsOf: url, options: ReadOptions(csv: CSVReadOptions(inferTypes: true)))
        #expect(whole.sheets[0].rows(in: "A2:C3") == Array(rows[1...2]))
        #expect(whole.sheets[0].rowCount == 20_003)
    }

    /// A multi-byte character and a CR LF cut by a piece boundary are not a fault.
    @Test func piecesMayCutCharactersAndLineEnds() throws {
        var text = ""
        for i in 0..<30_000 { text += "日本語の値\(i),\"引用, つき\"\r\n" }   // well past one piece of 256 KiB
        let reader = CSVStreamingReader(data: Data(text.utf8))
        var count = 0
        var last: [CellValue?] = []
        try reader.forEachRow { count += 1; last = $0 }
        #expect(count == 30_000)
        #expect(last == [.text("日本語の値29999"), .text("引用, つき")])
    }

    /// UTF-16 with a BOM, a `sep=` line, a `.tsv` name, a legacy encoding: the dialect and decoding rules hold.
    @Test func dialectsAndEncodingsAreHonoured() throws {
        var le = Data([0xFF, 0xFE])
        for u in "a\tb\r\n1\t2\r\n".utf16 { le.append(UInt8(u & 0xff)); le.append(UInt8(u >> 8)) }
        var rows: [[CellValue?]] = []
        try CSVStreamingReader(data: le, filename: "x.tsv").forEachRow { rows.append($0) }
        #expect(rows == [[.text("a"), .text("b")], [.text("1"), .text("2")]])
        rows = []
        try CSVStreamingReader(data: Data("sep=;\r\nx;y\r\n".utf8)).forEachRow { rows.append($0) }
        #expect(rows == [[.text("x"), .text("y")]])
        rows = []
        let sjis = "名前,値\r\n".data(using: .shiftJIS)!
        try CSVStreamingReader(data: sjis, options: CSVReadOptions(encoding: .shiftJIS)).forEachRow { rows.append($0) }
        #expect(rows == [[.text("名前"), .text("値")]])
    }

    @Test func recordsCanBeIteratedAsASequence() async throws {
        let reader = CSVStreamingReader(data: Data("a,b\n1,2\n3,4\n".utf8))
        var seen: [[CellValue?]] = []
        for try await row in reader.rows() { seen.append(row) }
        #expect(seen.count == 3 && seen[2] == [.text("3"), .text("4")])
    }
}

@Suite struct LazyRowTests {
    /// `for try await` over the rows: the same rows `forEachRow` delivers, pulled as the loop asks.
    @Test func rowsArriveAsASequence() async throws {
        var wb = Workbook()
        for i in 0..<5_000 { wb.sheets[0].append([.integer(i), .text("v\(i)")]) }
        let reader = try StreamingReader(data: try wb.data(as: .xlsx))
        var count = 0
        var last: StreamedRow?
        for try await row in reader.rows(inSheet: "Sheet1") { count += 1; last = row }
        #expect(count == 5_000)
        #expect(last?.index == 4_999 && last?.cells.last?.value == .text("v4999"))
        // stopping early is allowed and reads no further
        var first: StreamedRow?
        for try await row in reader.rows(inSheet: "Sheet1") { first = row; break }
        #expect(first?.index == 0)
    }

    @Test func anUnknownSheetThrowsFromTheSequence() async throws {
        var wb = Workbook(); wb.sheets[0]["A1"] = 1
        let reader = try StreamingReader(data: try wb.data(as: .xlsx))
        await #expect(throws: SheetError.self) {
            for try await _ in reader.rows(inSheet: "Nope") {}
        }
    }
}
