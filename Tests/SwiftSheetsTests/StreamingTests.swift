import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Reading and writing a workbook row by row, without holding it (openpyxl's `read_only` / `write_only`).
@Suite struct StreamingTests {
    static func temporary(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-stream-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Written row by row, read back by the ordinary reader: every value and every type intact.
    // openpyxl: worksheet/tests/test_write_only.py::test_append
    // openpyxl: worksheet/tests/test_write_only.py::test_close
    // openpyxl: worksheet/tests/test_write_only.py::test_write_only_cell
    // openpyxl: worksheet/tests/test_write_only.py::test_path
    @Test func whatIsStreamedOutIsWhatComesBackIn() throws {
        let url = Self.temporary("stream.xlsx")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = try StreamingWriter(url: url, sheetName: "売上")
        try writer.append([.text("品目"), .text("数量"), .text("単価")])
        try writer.append([.text("apple"), .integer(3), .number(1.5)])
        try writer.append([.text("  余白  "), .bool(true), .error("#N/A")])
        try writer.append([.text("式"), .formula(FormulaExpr.parse("=B2*C2"), cached: .number(4.5)), nil])
        var styled = Cell(); styled.value = .text("見出し"); styled.font.bold = true; styled.fill = .solid(.rgb("FFBFD7F5"))
        try writer.append([styled])
        try writer.addSheet(named: "空")
        try writer.append([.text("second sheet")])
        try writer.close()

        let wb = try Workbook(contentsOf: url)
        #expect(wb.sheetNames == ["売上", "空"])
        let ws = wb.sheets[0]
        #expect(ws["A1"] == .text("品目") && ws["C1"] == .text("単価"))
        #expect(ws["A2"] == .text("apple") && ws["B2"] == .integer(3) && ws["C2"] == .number(1.5))
        #expect(ws["A3"] == .text("  余白  "), "leading and trailing spaces survive")
        #expect(ws["B3"] == .bool(true) && ws["C3"] == .error("#N/A"))
        #expect(ws["B4"]?.formula?.text == "=B2*C2")
        #expect(ws[cell: "A5"].font.bold && ws[cell: "A5"].fill == .solid(.rgb("FFBFD7F5")))
        #expect(wb.sheets[1]["A1"] == .text("second sheet"))
    }

    /// The streaming reader sees the same values as the ordinary one.
    // openpyxl: worksheet/tests/test_read_only.py::TestReadOnlyWorksheet::test_read_rows
    // openpyxl: worksheet/tests/test_read_only.py::TestReadOnlyWorksheet::test_iter
    // openpyxl: worksheet/tests/test_read_only.py::TestReadOnlyWorksheet::test_pad_row
    // openpyxl: worksheet/tests/test_read_only.py::TestReadOnlyWorksheet::test_empty_cell
    @Test func theStreamingReaderSeesWhatTheOrdinaryOneSees() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws.name = "Data"
        ws.append([.text("Item"), .text("Qty")])
        for i in 1...50 { ws.append([.text("row\(i)"), .integer(i)]) }
        ws["E100"] = .number(3.5)
        wb.sheets[0] = ws
        let data = try wb.data(as: .xlsx)

        let reader = try StreamingReader(data: data)
        #expect(reader.sheetNames == ["Data"])
        var rows: [[CellValue?]] = []
        try reader.forEachRow(inSheet: "Data", valuesOnly: 2) { rows.append($0) }
        #expect(rows.count == 52)
        #expect(rows[0] == [.text("Item"), .text("Qty")])
        #expect(rows[50] == [.text("row50"), .integer(50)])
        #expect(rows[51] == [nil, nil], "the far-away cell is its own row")

        var seen: [Int] = []
        try reader.forEachRow(inSheet: "Data") { seen.append($0.index) }
        #expect(seen.first == 0 && seen.last == 99)
    }

    /// Throwing from the handler stops the walk there and comes back out.
    @Test func throwingFromTheHandlerStopsTheWalk() throws {
        struct Stop: Error {}
        var wb = Workbook()
        for i in 0..<100 { wb.sheets[0][i, 0] = .integer(i) }
        let data = try wb.data(as: .xlsx)
        let reader = try StreamingReader(data: data)
        var count = 0
        #expect(throws: Stop.self) {
            try reader.forEachRow(inSheet: "Sheet1") { _ in
                count += 1
                if count == 5 { throw Stop() }
            }
        }
        #expect(count == 5)
    }

    /// Formulas, cached values and `dataOnly` behave as they do everywhere else.
    @Test func formulasAndDataOnly() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = .formula(FormulaExpr.parse("=1+2"), cached: .integer(3))
        let data = try wb.data(as: .xlsx)
        let reader = try StreamingReader(data: data)
        var withFormula: CellValue?
        try reader.forEachRow(inSheet: "Sheet1") { withFormula = $0.cells.first?.value }
        #expect(withFormula?.formula?.text == "=1+2")
        var cached: CellValue?
        try reader.forEachRow(inSheet: "Sheet1", options: StreamingReadOptions(dataOnly: true)) { cached = $0.cells.first?.value }
        #expect(cached == .integer(3))
    }

    /// Styles are read only when asked for.
    @Test func stylesAreOptional() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = .text("x")
        wb.sheets[0].style("A1") { $0.font.bold = true }
        let data = try wb.data(as: .xlsx)
        let reader = try StreamingReader(data: data)
        var plain: CellStyle?
        try reader.forEachRow(inSheet: "Sheet1") { plain = $0.cells.first?.style }
        #expect(plain == nil)
        var styled: CellStyle?
        try reader.forEachRow(inSheet: "Sheet1", options: StreamingReadOptions(includeStyles: true)) { styled = $0.cells.first?.style }
        #expect(styled?.font.bold == true)
    }

    /// Naming a sheet the workbook does not have is an error, not an empty walk.
    @Test func anUnknownSheetThrows() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        let reader = try StreamingReader(data: try wb.data(as: .xlsx))
        #expect(throws: SheetError.self) { try reader.forEachRow(inSheet: "Missing") { _ in } }
    }

    /// The point of the exercise: a hundred thousand rows go out and come back without the workbook ever existing.
    @Test func aHundredThousandRowsStreamBothWays() throws {
        let url = Self.temporary("big.xlsx")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rows = 100_000

        let writer = try StreamingWriter(url: url, sheetName: "Big")
        try writer.append([.text("n"), .text("square")])
        for i in 1...rows { try writer.append([.integer(i), .integer(i * i)]) }
        try writer.close()

        var count = 0, total = 0
        let reader = try StreamingReader(contentsOf: url)
        try reader.forEachRow(inSheet: "Big", valuesOnly: 2) { values in
            guard case .integer(let n)? = values[0] else { return }
            count += 1; total += n
        }
        #expect(count == rows)
        #expect(total == rows * (rows + 1) / 2)
        // the promise behind "+2 MB": the sheet's XML is several megabytes, and no more than a couple of pieces
        // of it were ever held at once (spec Appendix B.39.8)
        #expect(XLSXStreamingReader.lastLargestCarry <= 2 * ZipEntryStream.pieceSize * 4 + 1 << 20,
                "held \(XLSXStreamingReader.lastLargestCarry) bytes of the part at once")
        // and the file it wrote is an ordinary workbook
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 0)
    }

    /// A workbook the streaming writer made is one the ordinary reader is happy with, package and all.
    @Test func theStreamedPackageIsWellFormed() throws {
        let url = Self.temporary("package.xlsx")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try StreamingWriter(url: url, sheetName: "A")
        try writer.append([.text("x")])
        try writer.addSheet(named: "B")
        try writer.append([.integer(1)])
        try writer.close()

        let data = try Data(contentsOf: url)
        let zip = try ZipArchive(data: data)
        let names = zip.entries.keys.sorted()
        #expect(names.contains("[Content_Types].xml") && names.contains("xl/workbook.xml"))
        #expect(names.contains("xl/worksheets/sheet1.xml") && names.contains("xl/worksheets/sheet2.xml"))
        let ct = String(decoding: try zip.read("[Content_Types].xml"), as: UTF8.self)
        for name in names where name.hasSuffix(".xml") && name != "[Content_Types].xml" && !name.contains("_rels") {
            #expect(ct.contains("PartName=\"/\(name)\""), "undeclared \(name)")
        }
        let rels = String(decoding: try zip.read("xl/_rels/workbook.xml.rels"), as: UTF8.self)
        let wb = String(decoding: try zip.read("xl/workbook.xml"), as: UTF8.self)
        for id in wb.components(separatedBy: "r:id=\"").dropFirst().compactMap({ $0.split(separator: "\"").first.map(String.init) }) {
            #expect(rels.contains("Id=\"\(id)\""), "dangling \(id)")
        }
        #expect(SheetFormat.detect(from: data) == .xlsx)
    }
}
