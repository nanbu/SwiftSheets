import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Sheets that are not grids (spec Appendix B.35).
///
/// A workbook may list a **chart sheet** — a chart that owns a whole tab — beside its worksheets. The model has no
/// word for one, and until this suite existed the reader parsed it as a worksheet: no cells, no warning, and a save
/// that wrote `<worksheet>` into the chart sheet's part while `[Content_Types].xml` went on calling it a chart
/// sheet. Nothing said so. These tests pin the fix: the part is carried, not interpreted.
///
/// The fixture is Microsoft Excel's own work — Excel 16.112.2 was driven over AppleScript to build a two-sheet
/// workbook and save it (`Tests/FixtureGenerator/make_chartsheet_fixture.py`), so what is being read is a chart
/// sheet as Excel writes one, not one this project imagined.
@Suite struct ChartSheetTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    static let soffice = ODSCodecTests.soffice
    static func fixture() throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent("chartsheet.xlsx")) }
    static func part(_ data: Data, _ name: String) throws -> Data { try ZipArchive(data: data).read(name) }

    @Test func aChartSheetIsReadAsASheetWithNoGrid() throws {
        let result = try XLSXCodec.read(try Self.fixture())
        #expect(result.workbook.sheetNames == ["Data", "Quantities"])
        #expect(result.workbook.sheets[0]["A1"] == .text("Item"))

        let chartSheet = result.workbook.sheets[1]
        #expect(chartSheet.cells.isEmpty)
        let foreign = try #require(chartSheet.preserved.foreignSheet)
        #expect(foreign.root == "chartsheet")
        #expect(foreign.contentType == "application/vnd.openxmlformats-officedocument.spreadsheetml.chartsheet+xml")
        #expect(foreign.relationshipType.hasSuffix("/chartsheet"))
        #expect(foreign.description == "a chart sheet")

        // the point of the warning: without it, "no cells" reads as "the sheet was empty"
        let said = result.warnings.filter { $0.sheet == "Quantities" }
        #expect(said.count == 1)
        #expect(said.first?.kind == .degraded)
        #expect(said.first?.message.contains("chart sheet") == true)
    }

    @Test func writingBackKeepsTheChartSheetExactlyAsItArrived() throws {
        let original = try Self.fixture()
        let wb = try XLSXCodec.read(original).workbook
        let out = try wb.write(as: .xlsx)
        #expect(out.warnings.isEmpty)

        // the part, and the chart it points at, are the same bytes
        #expect(try Self.part(out.data, "xl/chartsheets/sheet1.xml") == (try Self.part(original, "xl/chartsheets/sheet1.xml")))
        #expect(try Self.part(out.data, "xl/charts/chart1.xml") == (try Self.part(original, "xl/charts/chart1.xml")))

        // …and the package still calls it a chart sheet in both places that name a type
        let types = String(decoding: try Self.part(out.data, "[Content_Types].xml"), as: UTF8.self)
        #expect(types.contains("PartName=\"/xl/chartsheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.chartsheet+xml\""))
        let rels = String(decoding: try Self.part(out.data, "xl/_rels/workbook.xml.rels"), as: UTF8.self)
        #expect(rels.contains("relationships/chartsheet\" Target=\"chartsheets/sheet1.xml\""))

        // reading the result again finds the same two sheets, and says the same thing about the second
        let again = try XLSXCodec.read(out.data)
        #expect(again.workbook.sheetNames == ["Data", "Quantities"])
        #expect(again.workbook.sheets[1].preserved.foreignSheet?.root == "chartsheet")
    }

    @Test func cellsPutIntoAChartSheetAreReportedRatherThanLost() throws {
        var wb = try XLSXCodec.read(try Self.fixture()).workbook
        wb.sheets[1]["A1"] = "this has nowhere to go"
        let out = try wb.write(as: .xlsx)
        #expect(out.warnings.count == 1)
        #expect(out.warnings.first?.kind == .dropped)
        #expect(out.warnings.first?.sheet == "Quantities")
        #expect(out.warnings.first?.message.contains("not saved") == true)
        // and the promise the warning makes is kept: the part is still Excel's
        #expect(try Self.part(out.data, "xl/chartsheets/sheet1.xml") == (try Self.part(try Self.fixture(), "xl/chartsheets/sheet1.xml")))
    }

    @Test func convertingToAFormatWithoutChartSheetsSaysSo() throws {
        let wb = try XLSXCodec.read(try Self.fixture()).workbook
        let ods = try wb.write(as: .ods)
        #expect(ods.warnings.contains { $0.message.contains("cannot be carried into ODS") })
        // the sheet is still there by name, so a reader is not left wondering where it went
        #expect(try Workbook(data: ods.data).sheetNames == ["Data", "Quantities"])
    }

    /// The machine judge: LibreOffice renders the file we wrote to the same number of pages as Excel's original.
    /// Before the fix it rendered three pages to the original's two — the chart sheet had become a worksheet.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: ODSCodecTests.soffice),
                   "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeRendersTheSamePagesAsTheOriginal() throws {
        let original = try Self.fixture()
        let ours = try XLSXCodec.read(original).workbook.write(as: .xlsx).data
        #expect(try Self.pageCount(of: original) == (try Self.pageCount(of: ours)))
    }

    /// `soffice --headless --convert-to pdf`, counting the pages it drew.
    static func pageCount(of workbook: Data) throws -> Int {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-chartsheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("book.xlsx")
        try workbook.write(to: input)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: soffice)
        p.arguments = ["--headless", "--convert-to", "pdf", "--outdir", dir.path, input.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let pdf = try Data(contentsOf: dir.appendingPathComponent("book.pdf"))
        // "/Type /Page" not followed by "s" — the page objects, not the page tree
        var pages = 0
        let needle = Array("/Type /Page".utf8), alt = Array("/Type/Page".utf8)
        let bytes = [UInt8](pdf)
        for start in bytes.indices {
            for pattern in [needle, alt] where start + pattern.count < bytes.count {
                if Array(bytes[start..<(start + pattern.count)]) == pattern, bytes[start + pattern.count] != UInt8(ascii: "s") {
                    pages += 1
                }
            }
        }
        return pages
    }
}
