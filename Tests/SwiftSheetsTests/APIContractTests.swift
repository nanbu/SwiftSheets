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

        // several tables on one sheet: only Numbers keeps them, so XLSX must not be offered as the cure
        let tables = [ConversionWarning(.dropped, subject: .tables, sheet: "Canvas", message: "1 other table(s) not written")]
        #expect(WriteResult.suggest(from: tables, target: .ods, options: options)?.format == .numbers)
        #expect(WriteResult.suggest(from: tables, target: .xlsx, options: options)?.format == .numbers)
        #expect(WriteResult.suggest(from: tables, target: .numbers, options: options) == nil)

        // mixed loss: no format keeps both, so the named one is XLSX and the count is of what XLSX would keep
        let mixed = tables + [ConversionWarning(.dropped, subject: .objects, message: "chart dropped")]
        let suggestion = WriteResult.suggest(from: mixed, target: .ods, options: options)
        #expect(suggestion?.format == .xlsx)
        #expect(suggestion?.message.hasPrefix("1 element(s)") == true)   // the table is not counted: XLSX cannot keep it
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

    // MARK: - Editing a sheet in one scope is a transaction (spec Appendix B.30)

    struct Interrupted: Error {}

    /// The changes are in the workbook the moment the closure returns — no write-back to forget — and the
    /// closure's result comes through.
    @Test func editSheetAppliesOnReturn() throws {
        var wb = Workbook()
        let count = try wb.editSheet(named: "Sheet1") { sheet in
            sheet["B4"] = 1_380_000
            sheet["B5"] = Formula("=B4/B3")
            sheet.style("A1") { $0.font.bold = true }
            return sheet.cells.count
        }
        #expect(count == 3)
        #expect(wb.sheets[0]["B4"] == .integer(1_380_000))
        #expect(wb.sheets[0]["B5"]?.formula?.text == "=B4/B3")
        #expect(wb.sheets[0].style("A1").font.bold == true)
    }

    /// A closure that throws leaves the workbook exactly as it was — partial changes are discarded, not kept.
    @Test func editSheetDiscardsEverythingOnThrow() {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "before"
        let snapshot = wb
        #expect(throws: Interrupted.self) {
            try wb.editSheet(named: "Sheet1") { sheet in
                sheet["A1"] = "after"
                sheet["A2"] = 42
                throw Interrupted()
            }
        }
        #expect(wb == snapshot)
        // the index variant makes the same promise
        #expect(throws: Interrupted.self) {
            try wb.editSheet(at: 0) { sheet in
                sheet["A1"] = "after"
                throw Interrupted()
            }
        }
        #expect(wb == snapshot)
    }

    /// A name the workbook does not have is loud — the error names the sheet, and nothing is edited. Lookups
    /// stay Optional (`wb.sheets["X"]`); an operation that would otherwise do nothing in silence throws.
    @Test func editSheetSaysWhichSheetIsMissing() {
        var wb = Workbook()
        let snapshot = wb
        #expect(throws: SheetError.sheetNotFound(name: "Summery")) {
            try wb.editSheet(named: "Summery") { $0["A1"] = "lost" }
        }
        #expect(wb == snapshot)
        #expect(SheetError.sheetNotFound(name: "Summery").localizedDescription == "no sheet named Summery")
    }

    /// The write-back goes through the `Sheets` subscript, so a rename inside the closure behaves like any other
    /// rename: formulas referring to the sheet follow, and a colliding name gets the next free suffix.
    @Test func editSheetRenameFollowsTheUsualRules() throws {
        var wb = Workbook()
        wb.addSheet(named: "Report")
        wb.sheets[1]["A1"] = Formula("=Sheet1!B2")
        try wb.editSheet(named: "Sheet1") { $0.name = "Data" }
        #expect(wb.sheetNames == ["Data", "Report"])
        #expect(wb.sheets[1]["A1"]?.formula?.text == "=Data!B2")
        try wb.editSheet(named: "Data") { $0.name = "Report" }   // taken: de-duplicated, not clobbered
        #expect(wb.sheetNames == ["Report1", "Report"])
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
        // The line people actually copy. It drifted once: the 0.6.0 tag stayed put while thirty-nine commits of
        // ODS and Numbers work landed on top of it, so `from: "0.6.0"` fetched a build without any of it.
        #expect(readme.contains("from: \"\(SwiftSheetsInfo.version)\""),
                Comment(rawValue: "README's Installation pin must be from: \"\(SwiftSheetsInfo.version)\""))
        let changelog = try String(contentsOf: root.appending(path: "CHANGELOG.md"), encoding: .utf8)
        #expect(changelog.contains("## [\(SwiftSheetsInfo.version)]"),
                Comment(rawValue: "CHANGELOG must carry a section for \(SwiftSheetsInfo.version)"))
    }

    /// The published documents name the version too, in their `<title>` — the line a reader sees in the browser
    /// tab and in a search result. Two of them sat at 0.7.2 for three releases, because nothing was watching:
    /// the README's numbers were pinned by the test above and the documents' were not. Now they are. A page that
    /// does not name a version at all is fine; a page that names the wrong one is not.
    @Test func everyPublishedDocumentNamesTheCurrentVersion() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let docs = root.appending(path: "docs")
        var checked = 0
        for file in try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
        where file.pathExtension == "html" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard let open = text.range(of: "<title>"), let close = text.range(of: "</title>") else { continue }
            let title = String(text[open.upperBound..<close.lowerBound])
            guard let named = title.firstMatch(of: #/SwiftSheets \d+\.\d+\.\d+/#) else { continue }
            checked += 1
            #expect(String(named.output) == "SwiftSheets \(SwiftSheetsInfo.version)",
                    Comment(rawValue: "\(file.lastPathComponent) names \(named.output) in its title, "
                            + "but the library is \(SwiftSheetsInfo.version)"))
        }
        #expect(checked >= 3, "the documents that name a version should still be naming it")
    }

    /// The README's test count is a floor ("800+ tests"), and the floor cannot drift: it must equal the number of
    /// `@Test` declarations under `Tests/`, rounded down to the nearest hundred. Counting declarations in source
    /// stands in for counting at run time (a suite cannot ask the runner for its own total mid-run), and it counts
    /// the same unit the `swift test` summary reports — measured equal, 896 both ways, when this was written, with
    /// parameterised functions counting once on each side. The hand-written number this replaces was 57 behind.
    @Test func theReadmeSaysHowManyTestsThereAre() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var swiftFiles = 0, tests = 0
        let walker = FileManager.default.enumerator(at: root.appending(path: "Tests"), includingPropertiesForKeys: nil)
        while let file = walker?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            swiftFiles += 1
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
                // the attribute itself — `@Test`, `@Test(...)`, `@Test func ...` — never a mention in a comment,
                // which cannot start a trimmed line with anything but `//`
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "@Test" || trimmed.hasPrefix("@Test(") || trimmed.hasPrefix("@Test ") { tests += 1 }
            }
        }
        #expect(swiftFiles > 0, Comment(rawValue: "found no Swift files under Tests/ — the path derivation broke"))
        let claim = "**\((tests / 100 * 100).formatted(.number.locale(Locale(identifier: "en_US"))))+ tests**"
        let readme = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        #expect(readme.contains(claim),
                Comment(rawValue: "Tests/ holds \(tests) @Test functions; the README must say \(claim)"))
    }
}
