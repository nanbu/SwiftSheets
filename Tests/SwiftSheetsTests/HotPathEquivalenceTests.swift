import Foundation
import Testing
@testable import SheetCore
import SwiftSheets
@testable import SheetXLSX

/// The reading fast paths give the answers the slow paths gave: a numeric cell's text is trimmed only when an end is
/// not plain ASCII, an integer under a plain format is tried before a Double, and a namespace prefix is stripped by
/// bytes. Each case below is what the code before those changes answered.
struct HotPathEquivalenceTests {
    /// The value an XLSX reader makes of `<c><v>text</v></c>` under the General format.
    static func value(of text: String, type: String? = nil) throws -> CellValue? {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        let data = try wb.write(as: .xlsx).data
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: data)
        let t = type.map { " t=\"\($0)\"" } ?? ""
        let patched = sheet.replacingOccurrences(of: "<c r=\"A1\" t=\"s\"><v>0</v></c>", with: "<c r=\"A1\"\(t)><v>\(text)</v></c>")
        #expect(patched.contains("<c r=\"A1\"\(t)><v>\(text)</v></c>"))
        let repacked = try Package.repacking(data, replacing: "xl/worksheets/sheet1.xml", with: Data(patched.utf8))
        let whole = try Workbook.read(repacked, format: .xlsx).workbook.sheets[0]["A1"]
        var streamed: CellValue??
        try StreamingReader(data: repacked, format: .xlsx).forEachRow(inSheet: "Sheet1") { row in streamed = row.cells.first { $0.ref == CellRef("A1")! }?.value }
        #expect((streamed ?? nil) == whole, "the row-by-row reader answers as the whole-workbook reader does for \(text.debugDescription)")
        return whole
    }

    @Test func numbersReadAsTheyDid() throws {
        #expect(try Self.value(of: "42") == .integer(42))
        #expect(try Self.value(of: " 42 ") == .integer(42))
        #expect(try Self.value(of: "\n42\t") == .integer(42))
        #expect(try Self.value(of: "\u{A0}42") == .integer(42), "a non-breaking space is still trimmed")
        #expect(try Self.value(of: "+5") == .integer(5))
        #expect(try Self.value(of: "-0") == .integer(0))
        #expect(try Self.value(of: "4.5") == .number(Decimal(string: "4.5")!))
        #expect(try Self.value(of: "1E3") == .number(Decimal(1000)))
        #expect(try Self.value(of: "12345678901234567890") == .number(Decimal(string: "12345678901234567890")!))
        #expect(try Self.value(of: "abc") == nil)
        #expect(try Self.value(of: "") == nil)
    }

    @Test func sharedStringIndicesAndBooleansReadAsTheyDid() throws {
        #expect(try Self.value(of: "0", type: "s") == .text("x"))
        #expect(try Self.value(of: " 0 ", type: "s") == .text("x"))
        #expect(try Self.value(of: "1", type: "b") == .bool(true))
        #expect(try Self.value(of: " 1", type: "b") == .bool(true))
    }

    @Test func aNamespacePrefixIsStrippedByBytes() {
        #expect(XML.local("x:si") == "si")
        #expect(XML.local("si") == "si")
        #expect(XML.local("a:b:c") == "c")
        #expect(XML.local(":x") == "x")
        #expect(XML.local("x:") == "")
        #expect(XML.local("表:セル") == "セル")
        #expect(XML.local("table:table-cell") == "table-cell")
    }

    /// A dense rectangle's rows are written from the extent; the sheet part is the one the grouped walk writes, byte
    /// for byte — with styles, formulas, a hidden row, and row heights inside and outside the extent.
    @Test func theDenseRowWalkWritesWhatTheGroupedWalkWrites() throws {
        var wb = Workbook()
        for r in 1...50 {
            wb.sheets[0].append([.integer(r), .text("t\(r)"), .number(Decimal(r) / 4), r % 7 == 0 ? .formula("=A\(r)*2") : .bool(r % 2 == 0)])
        }
        wb.sheets[0].setHeight(30, ofRow: 5)
        wb.sheets[0].setHeight(12, ofRow: 80)
        wb.sheets[0].setRowDimension(3) { $0.hidden = true }
        wb.sheets[0].setStyle("B2:B10") { $0.font.bold = true }
        let offset = wb.addSheet(named: "Offset")
        for r in 3...12 { for c in 2...4 { wb.sheets[offset][r, c] = .integer(r * c) } }
        wb.sheets[offset].setHeight(20, ofRow: 1)
        let dense = try wb.write(as: .xlsx).data
        xlsxWriterForcesSparseRowWalk = true
        defer { xlsxWriterForcesSparseRowWalk = false }
        let grouped = try wb.write(as: .xlsx).data
        for part in ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
            #expect(try Package.part(part, of: dense) == Package.part(part, of: grouped), Comment(rawValue: part))
        }
    }
}
