import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS
import SheetXLSX
import SwiftSheets

/// The promises the API makes about itself: losses are reported in both directions, a range is a view rather than a
/// copy, a sheet reached by name is edited where it lies, an error says what went wrong, and the version the library
/// writes into files is the version it tells people about.
@Suite struct APIContractTests {
    /// An ODS whose single row claims to repeat far more cells than any budget allows.
    static func rleBomb() -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.3">
        <office:body><office:spreadsheet><table:table table:name="Bomb">
        <table:table-row table:number-rows-repeated="1048576"><table:table-cell office:value-type="string" table:number-columns-repeated="100"><text:p>x</text:p></table:table-cell></table:table-row>
        </table:table></office:spreadsheet></office:body></office:document-content>
        """
        var zip = ZipWriter()
        zip.add("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8), stored: true)
        zip.add("content.xml", Data(content.utf8))
        return zip.finish()
    }

    // MARK: - Reading reports its losses too

    /// Writing has always answered with `WriteResult`; reading now answers with `ReadResult`, and the same warnings
    /// ride along on the workbook so that the convenience initialiser cannot swallow them.
    @Test func readingReportsWhatItCouldNotCarryOver() throws {
        let data = Self.rleBomb()
        let result = try ODSCodec.read(data, options: ReadOptions(cellLimit: 10_000))
        #expect(!result.warnings.isEmpty)
        #expect(result.warnings.allSatisfy { $0.kind == .degraded })
        #expect(result.workbook.readWarnings == result.warnings)

        // the same file through the facade: the warnings are still there
        let wb = try Workbook(data: data, options: ReadOptions(cellLimit: 10_000))
        #expect(wb.readWarnings == result.warnings)
        #expect(try Workbook.read(data, options: ReadOptions(cellLimit: 10_000)).warnings == result.warnings)
    }

    /// The budget is the caller's to set (it used to be a constant inside the ODS reader).
    @Test func theCellBudgetIsAReadOption() throws {
        let data = Self.rleBomb()
        let small = try ODSCodec.read(data, options: ReadOptions(cellLimit: 5_000))
        let larger = try ODSCodec.read(data, options: ReadOptions(cellLimit: 50_000))
        #expect(small.workbook.sheets[0].cells.count <= 5_000)
        #expect(larger.workbook.sheets[0].cells.count > small.workbook.sheets[0].cells.count)
        #expect(larger.workbook.sheets[0].cells.count <= 50_000)
        #expect(ReadOptions().cellLimit == 1_000_000)
    }

    // MARK: - A suggestion names the format that would have kept the thing

    @Test func theSuggestedFormatFollowsWhatWasLost() {
        let options = WriteOptions(suggestionThreshold: 2)
        let macros = [ConversionWarning(.dropped, subject: .macros, message: "VBA project dropped"),
                      ConversionWarning(.dropped, subject: .objects, message: "chart dropped")]
        #expect(WriteResult.suggest(from: macros, target: .xlsx, options: options)?.format == .xlsm)

        let objects = [ConversionWarning(.dropped, subject: .objects, message: "chart dropped"),
                       ConversionWarning(.dropped, subject: .objects, message: "drawing dropped")]
        #expect(WriteResult.suggest(from: objects, target: .ods, options: options)?.format == .xlsx)
        // nothing better exists than the format already being written — say nothing rather than something wrong
        #expect(WriteResult.suggest(from: objects, target: .xlsx, options: options) == nil)
        // and below the threshold, with nothing wholesale lost, there is no suggestion at all
        #expect(WriteResult.suggest(from: [ConversionWarning(.degraded, subject: .formulas, location: CellRef("A1"), message: "x")],
                                    target: .ods, options: WriteOptions()) == nil)
    }

    /// A real conversion, end to end: xlsm → xlsx drops the macros and says which format keeps them.
    @Test func droppingMacrosSuggestsAMacroEnabledWorkbook() throws {
        var wb = Workbook()
        wb.preserved.sourceFormat = .xlsm
        wb.preserved.opaqueParts["xl/vbaProject.bin"] = Data([1, 2, 3])
        wb.sheets[0]["A1"] = "with macros"
        let result = try XLSXCodec.write(wb)
        #expect(result.warnings.contains { $0.subject == .macros })
        #expect(result.suggestion?.format == .xlsm)
        // written as .xlsm instead, nothing is lost and nothing is suggested
        let kept = try XLSMCodec.write(wb)
        #expect(kept.warnings.isEmpty && kept.suggestion == nil)
    }

    // MARK: - A range is a view

    @Test func aRangeIsALazyViewOverTheSheet() {
        var sheet = Workbook().sheets[0]
        for r in 0..<10 { sheet[r, 0] = .integer(r); sheet[r, 2] = .text("row \(r)") }
        let view = sheet.range("A3:C5")

        #expect(view.range == CellRange("A3:C5"))
        #expect(view.count == 3)
        #expect(view.map(\.count) == [3, 3, 3])
        #expect(view[CellRef("A3")!] == .integer(2))
        #expect(view["C5"] == .text("row 4"))
        #expect(view[0, 0] == .integer(2))          // relative to the range's top-left
        #expect(view[2, 2] == .text("row 4"))
        #expect(view[CellRef("A1")!] == nil)        // outside the range
        #expect(view.values == sheet.values(in: "A3:C5"))
        #expect(view.existingCells.map(\.ref.a1) == ["A3", "C3", "A4", "C4", "A5", "C5"])

        var seen: [CellValue?] = []
        for row in view { seen.append(row[0]) }
        #expect(seen == [.integer(2), .integer(3), .integer(4)])

        // it is a snapshot: editing the sheet afterwards does not change what the view shows
        sheet["A3"] = "changed"
        #expect(view["A3"] == .integer(2))
    }

    // MARK: - Reaching a sheet by name edits it in place

    @Test func mutatingASheetByNameKeepsItsIdentityAndItsCells() {
        var wb = Workbook()
        wb.addSheet(named: "Data")
        wb.sheets["Data"]?["A1"] = "written through the name"
        wb.sheets["Data"]?["B2"] = 42
        #expect(wb.sheets["Data"]?["A1"] == .text("written through the name"))
        #expect(wb.sheets["Data"]?["B2"] == .integer(42))
        #expect(wb.sheetNames == ["Sheet1", "Data"])   // still in its place, not appended again

        // renaming through the same path still rewrites the formulas that name it
        wb.sheets[0]["A1"] = Formula("=Data!A1")
        wb.sheets["Data"]?.name = "Master"
        #expect(wb.sheetNames == ["Sheet1", "Master"])
        #expect(wb.sheets[0]["A1"]?.formula?.rendered(as: .xlsx) == "Master!A1")

        // and the active sheet, likewise
        wb.activeSheet["C3"] = "active"
        #expect(wb.sheets[wb.activeIndex]["C3"] == .text("active"))
    }

    // MARK: - Errors, detection, version

    @Test func errorsReadWellWhereFoundationPutsThem() {
        let error: any Error = SheetError.malformedPart(path: "xl/worksheets/sheet1.xml", detail: "invalid row number")
        #expect(error.localizedDescription == "malformed part xl/worksheets/sheet1.xml: invalid row number")
        #expect((error as? LocalizedError)?.errorDescription == error.localizedDescription)
    }

    /// `canDecode` and `SheetFormat.detect` cannot disagree: they are the same rule now.
    @Test func everyCodecAnswersFromTheOneDetectionRule() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        for (format, decides) in [(SheetFormat.xlsx, XLSXCodec.canDecode), (.xlsm, XLSMCodec.canDecode), (.ods, ODSCodec.canDecode)] {
            let zip = try ZipInspection(data: try wb.data(as: format))
            #expect(SheetFormat.detect(in: zip) == format)
            #expect(decides(zip))
            for other in [XLSXCodec.canDecode, XLSMCodec.canDecode, ODSCodec.canDecode, NumbersCodec.canDecode]
            where !decides(zip) { #expect(!other(zip)) }
        }
    }

    /// The one place the version is written down, and the one place people read it.
    @Test func theReadmeSaysTheVersionTheLibraryWrites() throws {
        #expect(SwiftSheetsInfo.generator == "SwiftSheets/\(SwiftSheetsInfo.version)")
        #expect(SwiftSheetsInfo.appVersion == SwiftSheetsInfo.version.split(separator: ".").prefix(2).joined(separator: "."))
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        #expect(readme.contains("Status: **\(SwiftSheetsInfo.version)**"),
                Comment(rawValue: "README's status line must name \(SwiftSheetsInfo.version)"))
    }
}
