import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Spec §12, pillar 5: malformed, hostile or merely absurd input must land on a `SheetError` — never on a trap, a
/// hang, or an allocation sized by a number the file itself supplies. A library cannot let its caller lose the
/// process over someone else's file, so every case below is a regression test for a crash that used to happen.
@Suite struct MalformedInputTests {
    /// The smallest package Excel accepts, with the `<sheetData>` (and anything after it) supplied by the caller.
    static func xlsx(worksheetBody body: String) -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        </Relationships>
        """
        let worksheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\(body)</worksheet>
        """
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        zip.add("_rels/.rels", Data(rootRels.utf8))
        zip.add("xl/workbook.xml", Data(workbook.utf8))
        zip.add("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8))
        zip.add("xl/worksheets/sheet1.xml", Data(worksheet.utf8))
        return zip.finish()
    }

    static let oneCell = "<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData>"

    // MARK: - Coordinates

    /// The accumulators in `CellRef` are bounded while they are being filled, not after: 20 letters or 20 digits
    /// used to overflow `Int` and trap before the length check was ever reached.
    @Test func absurdCoordinatesAreRejectedInsteadOfOverflowing() {
        #expect(CellRef("A99999999999999999999") == nil)
        #expect(CellRef(String(repeating: "A", count: 40) + "1") == nil)
        #expect(CellRef.columnIndex(String(repeating: "A", count: 40)) == nil)
        #expect(RangeBounds(String(repeating: "9", count: 40)) == nil)
        #expect(CellRange("A1:" + String(repeating: "A", count: 40) + "9") == nil)
        // the legal extremes still parse, and one past the last row does not
        #expect(CellRef("XFD1048576") == CellRef(row: 1_048_575, col: 16_383))
        #expect(CellRef("A1048577") == nil)
        #expect(CellRef.columnIndex("XFD") == 16_383)
    }

    @Test func anImpossibleCellReferenceInAFileDoesNotTakeTheProcessDown() throws {
        let data = Self.xlsx(worksheetBody: "<sheetData><row r=\"1\"><c r=\"A99999999999999999999\"><v>1</v></c></row></sheetData>")
        let wb = try XLSXCodec.read(data).workbook
        // the reference is unusable, so the cell lands where the reader's cursor is — the file still opens
        #expect(wb.sheets[0].cells.count == 1)
    }

    /// `r` is written with an exponent by some producers, so it goes through `Double` — and `Int(1e300)` traps.
    @Test func anImpossibleRowNumberIsReportedAsMalformed() {
        let data = Self.xlsx(worksheetBody: "<sheetData><row r=\"1e300\"><c r=\"A1\"><v>1</v></c></row></sheetData>")
        #expect(throws: SheetError.self) { try XLSXCodec.read(data).workbook }
        #expect(SheetParser.rowNumber("1e300") == nil)
        #expect(SheetParser.rowNumber("0") == nil)
        #expect(SheetParser.rowNumber("-1") == nil)
        #expect(SheetParser.rowNumber("1.048573e6") == 1_048_573)
        #expect(SheetParser.rowNumber("23") == 23)
    }

    // MARK: - Formulas

    /// A recursive-descent parser walks the nesting; 20,000 parentheses used to exhaust the stack (and a background
    /// thread's stack is sixteen times smaller than the main one). Too-deep text is not an error the caller sees —
    /// it is kept verbatim, which is also what keeps the round trip lossless.
    @Test func aFormulaNestedPastTheLimitIsKeptVerbatimInsteadOfExhaustingTheStack() throws {
        let depth = 20_000
        let text = "SUM" + String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
        let expr = FormulaExpr.parse(text)
        #expect(expr.isUnparsed)
        #expect(expr.rendered(as: .xlsx) == text)

        let data = Self.xlsx(worksheetBody: "<sheetData><row r=\"1\"><c r=\"A1\"><f>\(text)</f><v>1</v></c></row></sheetData>")
        let wb = try XLSXCodec.read(data).workbook
        #expect(wb.sheets[0]["A1"]?.formula?.isUnparsed == true)
        // and it survives the trip back out
        let again = try XLSXCodec.read(try XLSXCodec.write(wb).data).workbook
        #expect(again.sheets[0]["A1"]?.formula?.rendered(as: .xlsx) == text)
    }

    @Test func formulasUpToTheLimitStillParse() {
        let deep = String(repeating: "(", count: FormulaParser.maxDepth - 8) + "1+2" + String(repeating: ")", count: FormulaParser.maxDepth - 8)
        #expect(!FormulaExpr.parse(deep).isUnparsed)
        // and the everyday shapes are nowhere near the limit
        #expect(!FormulaExpr.parse("=IF(SUM(A1:A9)>0,ROUND(AVERAGE(B1:B9)*(1+C1),2),\"\")").isUnparsed)
    }

    // MARK: - Containers

    @Test func aCentralDirectoryThatPointsPastTheEndOfTheFileIsCorrupt() {
        var bytes = [UInt8](Self.xlsx(worksheetBody: Self.oneCell))
        // the first central-directory entry's file-name length, blown up so the name would run off the end
        let signature: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        let start = (0..<(bytes.count - 4)).first { Array(bytes[$0..<($0 + 4)]) == signature }
        #expect(start != nil)
        if let p = start {
            bytes[p + 28] = 0xff; bytes[p + 29] = 0x7f
            #expect(throws: SheetError.self) { try ZipArchive(data: Data(bytes)) }
        }
    }

    @Test func aTruncatedPackageIsCorrupt() {
        let data = Self.xlsx(worksheetBody: Self.oneCell)
        #expect(throws: SheetError.self) { try ZipArchive(data: data.prefix(data.count / 2)) }
        #expect(throws: SheetError.self) { try ZipArchive(data: Data()) }
        #expect(throws: SheetError.self) { try ZipArchive(data: Data([0x50, 0x4b, 0x03, 0x04])) }
    }

    /// Every byte of a valid package, flipped one at a time at pseudo-random positions: whatever comes out, the
    /// answer is a workbook or a thrown error, never a signal. The generator is a fixed LCG so a failure is
    /// reproducible from the seed alone.
    @Test func randomCorruptionNeverCrashes() {
        let original = [UInt8](Self.xlsx(worksheetBody: """
        <sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><f>SUM(A1:A3)</f><v>6</v></c></row>\
        <row r="2"><c r="A2"><v>2.5</v></c></row></sheetData><mergeCells count="1"><mergeCell ref="A1:B1"/></mergeCells>
        """))
        var seed: UInt64 = 0x5EED_1234
        func next() -> UInt64 { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return seed >> 16 }
        for _ in 0..<200 {
            var bytes = original
            let i = Int(next() % UInt64(bytes.count))
            bytes[i] = UInt8(next() % 256)
            _ = try? Workbook(data: Data(bytes))
        }
    }

    // MARK: - Sizes the file declares

    /// `<mergeCell ref="A1:XFD1048576"/>` is 38 bytes of XML and seventeen billion cells. Reading it used to build
    /// one `Cell` per position; now the merge is what it says it is — a range, plus the anchor.
    @Test func aWholeSheetMergeDoesNotMaterialiseTheSheet() throws {
        let data = Self.xlsx(worksheetBody: """
        <sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData>\
        <mergeCells count="1"><mergeCell ref="A1:XFD1048576"/></mergeCells>
        """)
        let start = Date()
        let wb = try XLSXCodec.read(data).workbook
        #expect(Date().timeIntervalSince(start) < 1.0)
        let ws = wb.sheets[0]
        #expect(ws.cells.count == 1)
        #expect(ws["A1"] == .integer(1))
        #expect(ws.merges.map(\.a1) == ["A1:XFD1048576"])
        // and it comes back out unchanged
        let again = try XLSXCodec.read(try XLSXCodec.write(wb).data).workbook
        #expect(again.sheets[0].merges.map(\.a1) == ["A1:XFD1048576"])
        #expect(again.sheets[0].cells.count == 1)
    }

    @Test func mergingAndUnmergingAHugeRangeThroughTheAPIIsCheap() {
        var ws = Workbook().sheets[0]
        ws["A1"] = "title"
        let start = Date()
        ws.merge("A1:XFD1048576")
        #expect(ws.cells.count == 1)
        let removed = ws.unmerge("A1:XFD1048576")
        #expect(removed)
        #expect(Date().timeIntervalSince(start) < 1.0)
        #expect(ws.cells.count == 1 && ws["A1"] == .text("title"))
    }

    /// The anchor of a merge is the one cell the formatting rules may always bring into existence: the ODS writer
    /// hangs `number-columns-spanned` on it, so a merged band whose anchor is still empty has to keep its cell.
    @Test func aMergeAlwaysKeepsItsAnchorCell() throws {
        var ws = Workbook().sheets[0]
        ws.merge("A1:C1")
        #expect(ws.cell("A1") != nil)
        #expect(ws.cells.count == 1)   // the anchor, and nothing else

        var wb = Workbook()
        wb.sheets[0] = ws
        let again = try XLSXCodec.read(try XLSXCodec.write(wb).data).workbook
        #expect(again.sheets[0].merges.map(\.a1) == ["A1:C1"])
    }

    // MARK: - Writing

    /// Saving over the file you opened is the whole point of the library, so the bytes must land atomically —
    /// and replacing an existing file has to keep working.
    @Test func writingOverAnExistingFileReplacesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("book.xlsx")

        var wb = Workbook()
        wb.sheets[0]["A1"] = "first"
        try wb.write(to: url)
        #expect(try Workbook(contentsOf: url).sheets[0]["A1"] == .text("first"))

        wb.sheets[0]["A1"] = "second"
        try wb.write(to: url)
        #expect(try Workbook(contentsOf: url).sheets[0]["A1"] == .text("second"))
    }
}
