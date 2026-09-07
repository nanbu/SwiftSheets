import Foundation
import Testing
import SwiftSheets

@Suite struct PreservationAPITests {
    @Test func newAndEmptySheetsAreGridsRegardlessOfVisibility() {
        var sheet = Sheet(name: "Empty")
        sheet.state = .hidden
        #expect(sheet.contentState == .grid)
        let summary = Workbook().preservationSummary
        #expect(summary.sourceFormat == nil)
        #expect(summary.opaquePartCount == 0)
        #expect(!summary.hasVBAProject)
    }

    @Test(arguments: [SheetFormat.xlsx, .xlsm, .ods, .numbers])
    func selectedSheetsRemainDistinguishableAfterEditingAndMoving(_ format: SheetFormat) throws {
        var original = Workbook()
        original.sheets[0]["A1"] = "original"
        original.addSheet(named: "Read")
        original.addSheet(named: "Empty")
        let bytes = try original.write(as: format).data
        var workbook = try Workbook(data: bytes, options: ReadOptions(sheets: .named(["Read", "Empty"])))
        #expect(workbook.sheets[0].contentState == .unread)
        #expect(workbook.sheets[1].contentState == .grid)
        #expect(workbook.sheets[2].contentState == .grid)
        #expect(workbook.preservationSummary.sourceFormat == format)
        #expect(workbook.readWarnings.contains { $0.sheet == "Sheet1" && $0.kind == .degraded })
        workbook.sheets[0]["B2"] = "does not read the source"
        #expect(workbook.sheets[0].contentState == .unread)
        _ = workbook.renameSheet("Sheet1", to: "Unloaded")
        workbook.moveSheet(named: "Unloaded", to: 2)
        #expect(workbook.sheets[2].name == "Unloaded")
        #expect(workbook.sheets[2].contentState == .unread)
        // A copy gets its own preservation — it cannot claim the source's part path, r:id or sheetId, and the
        // source bytes are written once, under the original sheet. So the copy is a plain grid holding exactly
        // the cells the model had, and nothing of the part nobody read.
        let duplicated = workbook.duplicateSheet(named: "Unloaded", as: "Copy")
        let copy = try #require(duplicated)
        #expect(workbook.sheets[copy].contentState == .grid)
        #expect(workbook.sheets[copy]["B2"] == .text("does not read the source"))
        #expect(workbook.sheets[copy].extent == CellRange("B2:B2"))
        let result = try workbook.write(as: format)
        #expect(result.warnings.contains { $0.sheet == "Unloaded" && $0.kind == .dropped })
    }

    @Test func chartSheetStateAndPreservedBytesSurviveWriteBack() throws {
        let bytes = try ChartSheetTests.fixture()
        var workbook = try Workbook(data: bytes)
        #expect(workbook.sheets[0].contentState == .grid)
        #expect(workbook.sheets[1].contentState == .nonGrid)
        workbook.sheets[1]["A1"] = "cannot edit a chart sheet as a grid"
        #expect(workbook.sheets[1].contentState == .nonGrid)
        let result = try workbook.write(as: .xlsx)
        #expect(result.warnings.contains { $0.kind == .dropped && $0.sheet == "Quantities" })
        #expect(try ChartSheetTests.part(result.data, "xl/chartsheets/sheet1.xml") ==
                ChartSheetTests.part(bytes, "xl/chartsheets/sheet1.xml"))
        #expect(try Workbook(data: result.data).sheets[1].contentState == .nonGrid)
        // Leaving a chart sheet out of the selection does not make its kind unknown: the workbook relationship
        // says it is not a worksheet, so the reader reports .nonGrid without ever parsing the part.
        let selected = try Workbook(data: bytes, options: ReadOptions(sheets: .named(["Data"])))
        #expect(selected.sheets[1].contentState == .nonGrid, "an unselected tab keeps the kind its relationship declares")
        #expect(selected.readWarnings.contains { $0.sheet == "Quantities" && $0.message.contains("chart sheet") })
    }

    @Test func summaryIsASnapshotAndDoesNotCountFragmentsAsParts() {
        var workbook = Workbook()
        workbook.preserved.sourceFormat = .xlsm
        workbook.preserved.workbookFragments = [XMLFragment(element: "extLst", xml: "<extLst/>")]
        #expect(!workbook.preserved.isEmpty)
        #expect(workbook.preservationSummary.opaquePartCount == 0)
        workbook.preserved.parts["xl/vbaProject.bin"] = .bytes(Data([1, 2, 3]))
        let snapshot = workbook.preservationSummary
        workbook.preserved.parts.removeAll()
        #expect(snapshot.sourceFormat == .xlsm)
        #expect(snapshot.opaquePartCount == 1 && snapshot.hasVBAProject)
        #expect(workbook.preservationSummary.opaquePartCount == 0)
        #expect(!workbook.preservationSummary.hasVBAProject)
    }

    @Test func summaryLeavesCompressedPartsUntouched() throws {
        let payload = try #require(Deflate.compress(Data(repeating: 42, count: 4096)))
        var workbook = Workbook()
        workbook.preserved.parts["xl/media/image.bin"] = .compressed(payload: payload, method: 8, crc32: 0, uncompressedSize: 4096)
        #expect(workbook.preservationSummary.opaquePartCount == 1)
        guard case .compressed(let kept, _, _, _)? = workbook.preserved.parts["xl/media/image.bin"] else {
            Issue.record("summary expanded an opaque part"); return
        }
        #expect(kept == payload)
    }

    @Test func csvSummaryReportsItsSourceFormat() throws {
        let workbook = try Workbook(data: Data("name,value\napple,2\n".utf8), format: .csv)
        #expect(workbook.preservationSummary.sourceFormat == .csv)
        #expect(workbook.sheets[0].contentState == .grid)
    }
}
