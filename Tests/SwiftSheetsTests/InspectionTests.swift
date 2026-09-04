import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// `Workbook.inspect` (spec Appendix B.39.3): what a file declares about itself before any cell is read, so the
/// caller can decide how much of it to hold — the question the old million-cell ceiling used to answer for them.
@Suite struct InspectionTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    static func workbook(rows: Int, sheets: Int = 1) -> Workbook {
        var wb = Workbook()
        for s in 0..<sheets {
            if s > 0 { wb.addSheet(named: "S\(s)") }
            for r in 0..<rows { wb.sheets[s].append([.integer(r), .text("r\(r)"), .number(1.5)]) }
        }
        return wb
    }

    /// XLSX declares its used range at the top of each sheet; the count is the area of that range.
    @Test func anXLSXDeclaresItsRangeAndCount() throws {
        let data = try Self.workbook(rows: 100, sheets: 2).data(as: .xlsx)
        let summary = try Workbook.inspect(data)
        #expect(summary.format == .xlsx)
        #expect(summary.sheets.map(\.name) == ["Sheet1", "S1"])
        #expect(summary.sheets[0].declaredRange?.a1 == "A1:C100")
        #expect(summary.sheets[0].declaredCellCount == 300)
        #expect(summary.declaredCellCount == 600)
        #expect(summary.sheets[0].countedCellCount == nil, "not counted unless asked")
        #expect(summary.partCount > 5 && summary.expandedBytes > 0)
        #expect(summary.producer?.application == "SwiftSheets")
    }

    /// Counting walks the markup and finds what a read would hold — the same number the model has after reading.
    @Test func countingFindsWhatAReadWouldHold() throws {
        var wb = Self.workbook(rows: 50)
        wb.sheets[0]["Z1000"] = "far"                       // the declaration grows; the count does not follow it
        let data = try wb.data(as: .xlsx)
        let summary = try Workbook.inspect(data, options: InspectOptions(countCells: true))
        #expect(summary.sheets[0].declaredCellCount == 26 * 1000)
        #expect(summary.sheets[0].countedCellCount == 151)
        #expect(summary.sheets[0].rowCount == 51)
        #expect(try Workbook(data: data).sheets[0].table.cells.count == 151)
    }

    /// A chart sheet is a tab, not a grid; it is listed and marked.
    @Test func aChartSheetIsListedButNotAGrid() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("chartsheet.xlsx"))
        let summary = try Workbook.inspect(data)
        #expect(summary.sheets.contains { !$0.isGrid })
        #expect(summary.sheets.contains { $0.isGrid && $0.declaredCellCount != nil })
    }

    /// ODS says nothing up front, so the content is walked as bytes: the run-length counts are multiplied,
    /// never expanded, and the padding rows every ODS carries do not count.
    @Test func anODSCountsItsValuedCellsWithoutExpandingThem() throws {
        var wb = Self.workbook(rows: 40)
        wb.addSheet(named: "第二")
        wb.sheets[1]["B2"] = 7
        let data = try wb.data(as: .ods)
        let summary = try Workbook.inspect(data)
        #expect(summary.format == .ods)
        #expect(summary.sheets.map(\.name) == ["Sheet1", "第二"])
        #expect(summary.sheets[0].declaredCellCount == 120)
        #expect(summary.sheets[0].rowCount == 40)
        #expect(summary.sheets[1].declaredCellCount == 1)
        #expect(summary.sheets[0].declaredRange == nil, "ODS declares no range")
    }

    /// A run-length bomb — a kilobyte that describes a billion cells — is exactly what the summary is for: the
    /// number comes back without any of the cells being made.
    @Test func aRunLengthBombIsReportedNotExpanded() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.3">
        <office:body><office:spreadsheet><table:table table:name="Bomb">
        <table:table-row table:number-rows-repeated="1000000"><table:table-cell office:value-type="float" office:value="1" table:number-columns-repeated="1000"><text:p>1</text:p></table:table-cell></table:table-row>
        </table:table></office:spreadsheet></office:body></office:document-content>
        """
        let zip = ZipWriter()
        zip.add("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8), stored: true)
        zip.add("content.xml", Data(content.utf8))
        let summary = try Workbook.inspect(zip.finish())
        #expect(summary.sheets[0].declaredCellCount == 1_000_000_000)
        #expect(summary.sheets[0].rowCount == 1_000_000)
    }

    /// A Numbers table names its own rows and columns.
    @Test func aNumbersDocumentDeclaresItsTables() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("numbers/test-1.numbers"))
        let summary = try Workbook.inspect(data)
        #expect(summary.format == .numbers)
        #expect(!summary.sheets.isEmpty)
        let wb = try Workbook(data: data)
        for (s, sheet) in wb.sheets.enumerated() {
            #expect(summary.sheets[s].name == sheet.name)
            #expect(summary.sheets[s].tableCount == sheet.tables.count)
            let declared = sheet.tables.reduce(0) { $0 + $1.rowCount * $1.columnCount }
            #expect(summary.sheets[s].declaredCellCount! >= declared, "\(sheet.name): the declaration covers what was read")
        }
    }

    /// A text file is one sheet of as many rows as it has lines.
    @Test func aCSVCountsItsLines() throws {
        let summary = try Workbook.inspect(Data("a,b\n1,2\n3,4".utf8), format: .csv)
        #expect(summary.format == .csv)
        #expect(summary.sheets[0].rowCount == 3)
        #expect(summary.sheets[0].declaredCellCount == nil)
        #expect(summary.expandedBytes == 11)
    }

    /// An encrypted file is refused here as it is on reading, with the same reason.
    @Test func anEncryptedFileIsRefusedWithItsReason() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("encrypted/agile.xlsx"))
        #expect(throws: SheetError.unsupportedFeature(UnopenableInput.encryptedOOXML.reason)) { _ = try Workbook.inspect(data) }
    }

    /// From a file and from its bytes, the same answer.
    @Test func aFileAndItsBytesAgree() throws {
        let url = Self.fixtures.appendingPathComponent("styled.xlsx")
        #expect(try Workbook.inspect(contentsOf: url) == Workbook.inspect(try Data(contentsOf: url)))
    }

    /// The whole point: the ceiling is chosen from the declaration, by the caller.
    @Test func theDeclarationChoosesTheCeiling() throws {
        let data = try Self.workbook(rows: 200).data(as: .xlsx)
        let declared = try Workbook.inspect(data).declaredCellCount!
        let wb = try Workbook(data: data, options: ReadOptions(cellLimit: declared))
        #expect(wb.sheets[0].table.cells.count == 600)
    }

    /// The byte scanner on its own: prefixes, entities, quotes, tags split across pieces.
    @Test func theTagScannerSeesTagsAcrossPieceBoundaries() throws {
        let xml = "<a><t:row n=\"1\"><t:cell v='x&amp;y'/></t:row><!-- <row/> --><![CDATA[<row/>]]><t:row n=\"2\"/></a>"
        let bytes = Array(xml.utf8)
        for cut in 1..<bytes.count {
            var pieces = [Data(bytes[..<cut]), Data(bytes[cut...])]
            var seen: [String] = []
            try TagScanner.scan({ pieces.isEmpty ? nil : pieces.removeFirst() }, names: ["row", "cell"]) { tag in
                seen.append((tag.isEnd ? "/" : "") + tag.localName + (tag.attribute("n").map { "#" + $0 } ?? "") + (tag.attribute("v").map { "=" + $0 } ?? ""))
                return true
            }
            #expect(seen == ["row#1", "cell=x&y", "/row", "row#2"], "cut at \(cut)")
        }
    }
}
